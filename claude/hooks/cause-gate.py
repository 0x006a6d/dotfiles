#!/usr/bin/env python3
# 原因を確かめる前のコード書き換えを止める PreToolUse フック。
# コードのファイル（.py .gd .js .ts .swift .sh など）を Edit/Write するとき、
# または Bash でそれらを書き換えるとき（sed -i、> へのリダイレクト、tee、open(..., 'w')、cp/mv の書き込み先）に、
# その会話の記録 ~/.claude/cause_gate/<session_id>.md を見て次を満たさなければ止める
# （会話ごとに分けるのは、1 つのファイルだとほかの会話が書いた記録で通ったり止まったりするため）。
#   - 3 時間以内に書かれている
#   - 「mode: 修正」なら「原因:」と「直す1点:」と「card:」の行が空でなく、card のノートに今日の日付の
#     「- YYYY-MM-DD claude:」コメントで「原因」を含む行がある
#   - 「mode: 診断」なら「診断:」の行が空でない（設定しなければ動作が変わらない切り替えだけを足すとき）
# 止めるときは exit 2 と理由（stderr）を返す。コード以外のファイルと読み取りだけのコマンドは通す。
import json, os, re, sys, time, datetime

GATE_DIR = os.path.expanduser("~/.claude/cause_gate")
CODE = r"\.(py|gd|gdshader|js|mjs|ts|tsx|swift|sh|lua|c|cc|cpp|h|hpp|rs|go)\b"
MAXAGE = 3 * 3600


def block_with(msg, gate):
    sys.stderr.write("[cause-gate] " + msg + "\n"
                     "コードを書き換える前に、この会話の記録 " + gate + " を書く:\n"
                     "  mode: 修正\n"
                     "  card: <カードのパス>\n"
                     "  原因: <確定した原因>\n"
                     "  直す1点: <直す1点>\n"
                     "  （カードに今日の claude: コメントで原因を書いておく）\n"
                     "  診断用の切り替えだけなら次の 2 行:\n"
                     "  mode: 診断\n"
                     "  診断: <何を確かめるか>\n")
    sys.exit(2)


def targets(tool, ti):
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        p = ti.get("file_path") or ti.get("notebook_path") or ""
        return [p] if re.search(CODE + r"$", p) else []
    if tool != "Bash":
        return []
    c = ti.get("command", "")
    out = []
    pats = [r"sed\s+-i\S*\s+.*?(\S+" + CODE + r")",
            r">>?\s*['\"]?(\S+" + CODE + r")",
            r"\btee\s+(?:-a\s+)?['\"]?(\S+" + CODE + r")",
            r"open\(\s*['\"]([^'\"]+" + CODE + r")['\"]\s*,\s*['\"][wa]",
            r"\b(?:cp|mv|install)\s+(?:-\S+\s+)*\S+\s+['\"]?(\S+" + CODE + r")['\"]?\s*(?:;|&|\||$)"]
    for p in pats:
        for m in re.finditer(p, c, re.M):
            out.append(m.group(1))
    # open(W + 'x.py', 'w') のような組み立てたパスや、変数 s を書き戻す open('...py','w').write(s) も拾う
    if re.search(r"open\([^)]*" + CODE + r"[^)]*,\s*['\"][wa]['\"]\)", c):
        out.append("(python write to code file)")
    # 退避用のコピー（名前に区切られた before / backup / bak か _v数字 を含む書き込み先）は実装を変えないので通す
    return [t for t in out if not t.startswith("/dev/")
            and not re.search(r"(?:^|[._-])(?:before|backup|bak)(?:[._-]|$)|_v\d+", os.path.basename(t))]


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    t = targets(d.get("tool_name", ""), d.get("tool_input", {}) or {})
    if not t:
        sys.exit(0)
    # session_id は変換せずに記録名にする（文字を消すと別の会話と同じ記録を指しうる）
    sid = d.get("session_id", "")
    GATE = os.path.join(GATE_DIR, sid + ".md")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        block_with("session_id が無いか、記録名に使えない文字を含む（" + sid[:40] + "）。", GATE_DIR + "/<session_id>.md")

    try:
        os.makedirs(GATE_DIR, exist_ok=True)     # 止めたときに示すパスへそのまま書けるように
    except OSError as e:
        block_with("記録のフォルダを作れない（" + str(e) + "）。", GATE)

    def block(msg):
        block_with(msg, GATE)
    if os.path.islink(GATE):
        block("この会話の原因の記録がリンクになっている（ほかの記録は使わない）。")
    if not os.path.exists(GATE):
        block("この会話の原因の記録がない。書き換え先: " + ", ".join(t[:3]))
    if time.time() - os.path.getmtime(GATE) > MAXAGE:
        block("この会話の原因の記録が 3 時間より古い。今の書き換えの原因を書き直す。")
    g = open(GATE, encoding="utf-8").read()

    def field(k):
        m = re.search(r"^[ \t]*" + k + r"[ \t]*[:：][ \t]*(.+)$", g, re.M)   # 空の項目が次の行で埋まらないよう改行はまたがない
        return m.group(1).strip() if m else ""
    mode = field("mode")
    if mode == "診断":
        if not field("診断"):
            block("mode: 診断 なのに「診断:」が空。")
        sys.exit(0)
    if mode != "修正":
        block("mode が「修正」か「診断」になっていない。")
    for k in ("原因", "直す1点", "card"):
        if not field(k):
            block("「" + k + ":」が空。")
    card = os.path.expanduser(field("card"))
    if not os.path.isfile(card):
        block("card のノートが見つからない: " + card)
    today = datetime.date.today().isoformat()
    lines = [l for l in open(card, encoding="utf-8").read().splitlines()
             if l.startswith("- " + today + " claude:") and "原因" in l]
    if not lines:
        block("カードに今日（" + today + "）の claude: コメントで原因を書いた行がない。")
    sys.exit(0)


main()
