#!/bin/bash
# PreToolUse(Bash) guard: 過去セッションで実害のあった 4 パターンを機械的に防ぐ
# 1) sudo は TTY が無く必ず失敗  2) poptones での一括 git add (CRLF 巻き込み)
# 3) git commit/push 前の秘密情報スキャン  4) push 時の remote URL ユーザー名欠落 (GCM ハング)
#
# これは踏み抜き防止であって安全境界ではない。コマンド文字列の見た目で判定するので、
# 変数展開・エイリアス・サブシェル・スクリプト経由の実行はすり抜ける。
# 秘密情報の混入を確実に止めたいなら各リポジトリの pre-commit フックでやること。
# リポジトリの特定は `git -C <dir>` と先頭の `cd <dir> &&` (引用符付きも可) を見る。それ以外の形
# (途中で cd する、パス変数を使う等) は hook 起動時の cwd で判定する。

INPUT=$(cat)
eval "$(printf '%s' "$INPUT" | python3 -c '
import json, os, re, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cmd = (d.get("tool_input") or {}).get("command", "")
cwd = d.get("cwd", "")
# git の対象ディレクトリを拾う: `git -C <dir>` / 先頭の `cd <dir> &&`
# -C は git 直後のグローバルオプション位置にあるものだけを見る
# (echo -C /other && git commit のような形で別リポを掴まないため)
def split(text):
    # バッククォートのコマンド置換は区切りとして扱う (`git commit` を git として拾うため)
    lexer = shlex.shlex(text.replace("`", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)

# commit/push の判定は git のサブコマンドで行う。文字列一致だと
# `coderabbit review --committed` や本文に commit を含むヒアドキュメントまで止まる。
# 分割できない (引用符の対応が取れない) ときは取りこぼさないよう従来の文字列一致に戻す
target = ""
first_c = ""
subcmds = []
# commit/push をする git ごとの -C。"" は -C 無し (先頭の cd か hook の cwd) を表す
commit_dirs = set()
try:
    tokens = split(cmd)
    parsed = True
except ValueError:
    tokens = []
    parsed = False
pending = list(tokens)
seen = 0
while pending and seen < 2000:
    seen += 1
    t = pending.pop(0)
    # bash -c "git commit ..." のように引用符の中にあるコマンドも見る
    if " " in t and "git" in t:
        try:
            pending = split(t) + pending
        except ValueError:
            parsed = False
        continue
    if t != "git" and not t.endswith("/git"):
        continue
    dir_arg = ""
    while pending:
        if pending[0] == "-C" and len(pending) > 1:
            dir_arg = pending[1]
            pending = pending[2:]
            continue
        if pending[0].startswith("-"):
            n = 2 if pending[0] in ("-c", "--git-dir", "--work-tree", "--namespace") else 1
            pending = pending[n:]
            continue
        break   # サブコマンドに到達
    sub = pending[0] if pending else ""
    subcmds.append(sub)
    if dir_arg and not first_c:
        first_c = dir_arg
    if sub in ("commit", "push"):
        commit_dirs.add(dir_arg)
# 上限で打ち切って見ていないトークンが残ったら、従来の文字列一致で判定する
if pending:
    parsed = False
# 検査対象は commit/push をする git の -C だけ。無関係な git -C /other status を
# 検査すると、実際に commit するリポジトリを調べずに通してしまう
ambiguous = len(commit_dirs) > 1
if commit_dirs:
    target = next(iter(commit_dirs))
else:
    target = first_c
if not target and len(tokens) >= 3 and tokens[0] == "cd" and tokens[2] in ("&&", ";"):
    target = tokens[1]
# シェルは ~ を展開するが shlex はしない
target = os.path.expanduser(target) if target else target
if parsed:
    is_commit = "commit" in subcmds
    is_push = "push" in subcmds
else:
    is_commit = re.search(r"git\s.*commit", cmd) is not None
    is_push = re.search(r"git\s.*push", cmd) is not None
print("CMD=" + shlex.quote(cmd))
print("IS_COMMIT=" + ("1" if is_commit else "0"))
print("IS_PUSH=" + ("1" if is_push else "0"))
print("AMBIGUOUS=" + ("1" if ambiguous else "0"))
print("CWD=" + shlex.quote(cwd))
print("GIT_DIR_ARG=" + shlex.quote(target))
')"

# git の検査対象はコマンドが指すディレクトリ。無ければ hook の cwd
[ -n "${GIT_DIR_ARG:-}" ] && CWD="$GIT_DIR_ARG"

# サブコマンド判定用に `-C <dir>` を落とした形も持つ
# (git -C <dir> add -A のように間にパスが挟まると素の正規表現が当たらない)
CMD_NORM=$(printf '%s' "$CMD" | sed -E 's/(^|[[:space:]])-C[[:space:]]+[^[:space:]]+/\1/g')

[ -z "$CMD" ] && exit 0

# 1) sudo guard — パスワード無しで通る箱では止めない
#    (旧母艦は NOPASSWD 不可で必ず失敗したが、箱ごとに事情が違うので実際に試して判定する)
if [[ "$CMD" =~ (^|[[:space:];\&\|\(])(/usr/bin/|/bin/)?sudo[[:space:]] ]]; then
  if ! command sudo -n true 2>/dev/null; then
    echo "BLOCKED: この箱では sudo にパスワードが要り、非対話シェルでは 'a terminal is required to read the password' で必ず失敗する。ユーザーに '! <command>' での実行を依頼するか、root 不要の代替 (~/.local/bin 直置き等) を使うこと。" >&2
    exit 2
  fi
fi

# 2) poptones bulk add guard
#    この箱はユーザー名が poptones で、ホーム配下のパスが全部 *poptones* に一致してしまう。
#    ブログ poptones のリポジトリ (トップレベル名が poptones) だけを対象にする。
REPO_TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
if [[ "$(basename "${REPO_TOP:-}")" == "poptones" ]]; then
  if [[ "$CMD_NORM" =~ git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*add[[:space:]]+(.*[[:space:]])?(-A|--all|\.)([[:space:]]|$) ]]; then
    echo "BLOCKED: poptones リポでの一括 git add は CRLF ノイズの全ファイルを巻き込む (再発多数)。対象記事の ja/en ファイルを明示パスで add すること。実質差分の確認は git diff --ignore-all-space --stat。" >&2
    exit 2
  fi
fi

# 3) secret scan before commit/push
SECRET_RE='sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY'
# 対象リポジトリを特定できないまま素通しすると、スキャンしていないのに
# 「秘密情報なし」と同じ結果になる。commit/push に限って止める
if [ "$AMBIGUOUS" = 1 ]; then
  echo "BLOCKED: 1 つのコマンドで複数のリポジトリへ commit/push しようとしている。秘密情報スキャンの対象を 1 つに決められないので、リポジトリごとに分けて実行すること。" >&2
  exit 2
fi
if { [ "$IS_COMMIT" = 1 ] || [ "$IS_PUSH" = 1 ]; } && [ -z "$REPO_TOP" ]; then
  echo "BLOCKED: このコマンドの対象リポジトリを特定できず、秘密情報スキャンができない (cwd=$CWD)。'git -C <repo> ...' の形で実行するか、リポジトリ直下で実行すること。" >&2
  exit 2
fi
if [ "$IS_COMMIT" = 1 ]; then
  # index だけでは足りない: -a/--all/--only/--include/pathspec 付き commit は
  # 作業ツリーの内容を取り込む。形を数えるより両方見るほうが漏れない
  SCAN="$(git -C "$CWD" diff --cached 2>/dev/null)
$(git -C "$CWD" diff 2>/dev/null)"
  if printf '%s' "$SCAN" | grep -qE "$SECRET_RE"; then
    echo "BLOCKED: コミット対象の差分に秘密情報らしきパターン (APIキー/トークン/秘密鍵) を検出。unstage して確認すること。過去に public リポへの sk- キー push 未遂あり。" >&2
    exit 2
  fi
fi
if [ "$IS_PUSH" = 1 ]; then
  # upstream 未設定 (git push -u の初回) では @{u} が解決できない。
  # その場合は remote に無いコミット全部を見る
  # 履歴は切り詰めずに grep へ流す (grep -q は一致した時点で打ち切る)
  if git -C "$CWD" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    UNPUSHED_CMD=(log -p '@{u}..')
  else
    # HEAD を明示しないと (--not --remotes だけでは) 範囲が空になり何も出ない
    UNPUSHED_CMD=(log -p HEAD --not --remotes)
  fi
  if git -C "$CWD" "${UNPUSHED_CMD[@]}" 2>/dev/null | grep -qE "$SECRET_RE"; then
    echo "BLOCKED: 未 push コミットに秘密情報らしきパターンを検出。push 前に履歴から除去すること (git reset / rebase)。" >&2
    exit 2
  fi
  # 4) remote URL username check (GCM account-picker hang)
  #    どちらの形が通るかは箱によって違う (資格情報キーが host のみか user@host か)。
  #    実際に credential fill を引いて、資格情報が取れる形かどうかで判定する。
  # push 先は origin とは限らない。明示 remote → pushRemote → pushDefault → origin の順
  PUSH_REMOTE=$(printf '%s' "$CMD_NORM" | sed -nE 's/.*git[[:space:]]+([^|;&]*[[:space:]])?push[[:space:]]+((-[^[:space:]]+[[:space:]]+)*)([^-][^[:space:]]*).*/\4/p')
  if [ -z "$PUSH_REMOTE" ]; then
    BR=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)
    PUSH_REMOTE=$(git -C "$CWD" config --get "branch.$BR.pushRemote" 2>/dev/null)
    [ -z "$PUSH_REMOTE" ] && PUSH_REMOTE=$(git -C "$CWD" config --get remote.pushDefault 2>/dev/null)
    [ -z "$PUSH_REMOTE" ] && PUSH_REMOTE=$(git -C "$CWD" config --get "branch.$BR.remote" 2>/dev/null)
    [ -z "$PUSH_REMOTE" ] && PUSH_REMOTE=origin
  fi
  URL=$(git -C "$CWD" remote get-url "$PUSH_REMOTE" 2>/dev/null)
  # remote 名ではなく URL を直接書いた push もある
  [ -z "$URL" ] && [[ "$PUSH_REMOTE" == *://* ]] && URL="$PUSH_REMOTE"
  if [[ -n "$URL" && "$URL" =~ ^https://([^@/]+@)?github\.com/ ]]; then
    # URL に username があればそれも渡す (資格情報キーが user@host の箱ではそれが正)
    USERLINE=""
    [[ -n "${BASH_REMATCH[1]}" ]] && USERLINE="username=${BASH_REMATCH[1]%@}
"
    # timeout は settings.json の hook timeout(20秒)より十分短くする。
    # hook 自体が timeout すると出力が捨てられ、ガードを通さず実行される
    if ! printf 'protocol=https\nhost=github.com\n%s\n' "$USERLINE" | timeout 5 git credential fill 2>/dev/null | grep -q '^password='; then
      echo "BLOCKED: github.com の資格情報を credential fill で引けない。この状態の push は Windows GCM の認証待ちでハングする。先に Windows 側で GCM のブラウザ OAuth を 1 回通すか、'! git -C <repo> push' で手動実行すること。" >&2
      exit 2
    fi
  fi
fi

exit 0
