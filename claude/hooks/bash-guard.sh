#!/bin/bash
# PreToolUse(Bash) guard: 過去セッションで実害のあった 4 パターンを機械的に防ぐ
# 1) sudo は TTY が無く必ず失敗  2) poptones での一括 git add (CRLF 巻き込み)
# 3) git commit/push 前の秘密情報スキャン  4) push 時の remote URL ユーザー名欠落 (GCM ハング)
#
# これは踏み抜き防止であって安全境界ではない。コマンド文字列の見た目で判定するので、
# 変数展開・エイリアス・サブシェル・スクリプト経由の実行はすり抜ける。
# 秘密情報の混入を確実に止めたいなら各リポジトリの pre-commit フックでやること。
# リポジトリの特定は `git -C <dir>` と先頭の `cd <dir> &&` を見る。それ以外の形
# (途中で cd する、パス変数を使う等) は hook 起動時の cwd で判定する。

INPUT=$(cat)
eval "$(printf '%s' "$INPUT" | python3 -c '
import json, re, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cmd = (d.get("tool_input") or {}).get("command", "")
cwd = d.get("cwd", "")
# git の対象ディレクトリを拾う: `git -C <dir>` / 先頭の `cd <dir> &&`
# -C は git 直後のグローバルオプション位置にあるものだけを見る
# (echo -C /other && git commit のような形で別リポを掴まないため)
target = ""
try:
    tokens = shlex.split(cmd)
except ValueError:
    tokens = []
for i, t in enumerate(tokens):
    if t != "git" and not t.endswith("/git"):
        continue
    j = i + 1
    while j < len(tokens):
        if tokens[j] == "-C" and j + 1 < len(tokens):
            target = tokens[j + 1]
            break
        if tokens[j].startswith("-"):
            j += 2 if tokens[j] in ("-c", "--git-dir", "--work-tree", "--namespace") else 1
            continue
        break   # サブコマンドに到達
    if target:
        break
if not target:
    m = re.match(r"\s*cd\s+([^\s;&|]+)\s*(&&|;)", cmd)
    if m:
        target = m.group(1).strip("\"\x27")
print("CMD=" + shlex.quote(cmd))
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
if [[ "$CMD_NORM" =~ git[[:space:]].*(commit|push) ]] && [ -z "$REPO_TOP" ]; then
  echo "BLOCKED: このコマンドの対象リポジトリを特定できず、秘密情報スキャンができない (cwd=$CWD)。'git -C <repo> ...' の形で実行するか、リポジトリ直下で実行すること。" >&2
  exit 2
fi
if [[ "$CMD_NORM" =~ git[[:space:]].*commit ]]; then
  # index だけでは足りない: -a/--all/--only/--include/pathspec 付き commit は
  # 作業ツリーの内容を取り込む。形を数えるより両方見るほうが漏れない
  SCAN="$(git -C "$CWD" diff --cached 2>/dev/null)
$(git -C "$CWD" diff 2>/dev/null)"
  if printf '%s' "$SCAN" | grep -qE "$SECRET_RE"; then
    echo "BLOCKED: コミット対象の差分に秘密情報らしきパターン (APIキー/トークン/秘密鍵) を検出。unstage して確認すること。過去に public リポへの sk- キー push 未遂あり。" >&2
    exit 2
  fi
fi
if [[ "$CMD_NORM" =~ git[[:space:]].*push ]]; then
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
