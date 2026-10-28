#!/usr/bin/env python3
# 指示や承認された作り方（原文）に無いやり方で進むのを止める PreToolUse フック。常に働く。
# 照合は会話の記録だけで行う（ファイルを使わないので、ほかの会話と混ざらない）。
# 実行・生成・書き込み（Edit/Write、Bash の書き込みや python/godot/blender/curl -d など、Blender MCP のコード実行）は、
# ユーザーの最後の発言より後に、Claude が何もしないコマンド : '原文: … / やること: … / 原文に無いこと: …' を
# 打って次の項目を揃えていなければ止める（返答の文は作業の途中では記録に入らないので、コマンドで書く）。
#   原文: <この会話にそのまま出ている文（ユーザーの発言、またはツールの結果として出た投稿などの文）>
#   やること: <これからやること>
#   原文に無いこと: なし ／ <原文に書いていない作り方・モデル・分け方など>
#   承認: <原文に無いことがあるとき、それを初めて書いた後のユーザーの発言をそのまま>
# カード（0000_ToDo 配下）への書き込みと cause_gate.md、読むだけのコマンドは通す。
# ユーザーが ~/.claude/step_gate_off を置いた間は何も止めない（このフックを直すときに使う）。
# それ以外のとき、このフック・settings.json・step_gate_off を Claude が書き換えるのは止める。
import json, os, re, sys, datetime

HOME = os.path.expanduser("~")
OFF = HOME + "/.claude/step_gate_off"
FREE = ("/0000_ToDo/", HOME + "/.claude/cause_gate.md")
GUARD = r"(step-gate\.py|cause-gate\.py|step_gate_off|settings\.json)"
RUNS = r"(\bpython\d?(\.\d+)?\b|(?:^|[;&|(]\s*)\S*\.py\b|godot|blender|\bffmpeg\b|\bcurl\b[^|;&]*\s(-d|--data|-X\s*POST|-F)\b|\bgit\s+(commit|push)\b)"
WRITECMD = r"\b(cp|mv|rm|mkdir|touch|install|ln|chmod|sed\s+-i)\b"
WRITES = r"(>|\btee\b|" + WRITECMD + ")"
DECL = re.compile(r"\s*:\s+'[^']*'\s*")
EDITS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def block(msg):
    sys.stderr.write("[step-gate] " + msg + "\n"
                     "手を動かす前に、何もしないコマンドを 1 回打って書く（ユーザーの最後の発言より後に）:\n"
                     "  : '原文: … / やること: … / 原文に無いこと: なし'\n"
                     "  原文: <この会話にある指示・承認された作り方の文を、今の段の分だけそのまま>\n"
                     "  やること: <これからやること>\n"
                     "  原文に無いこと: なし ／ <原文に書いていない作り方・モデル・分け方など>\n"
                     "  承認: <原文に無いことがあるとき、それを書いた後のユーザーの発言をそのまま>\n"
                     "原文に無いことがあってユーザーの承認が無いなら、作業を止めて、何が原文に書いていないかをユーザーに伝える。\n")
    sys.exit(2)


def ts_of(d):
    try:
        return datetime.datetime.fromisoformat(d.get("timestamp", "").replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def real_user(s):
    s = s.strip()
    return bool(s) and not s.startswith("<") and not s.startswith("[Request interrupted")


def transcript(tp):
    # (時刻, 種類, 文)。種類は user（ユーザーの発言）/ result（ツールの結果）/ claude（Claude が打った宣言のコマンド）
    out = []
    try:
        lines = open(tp, encoding="utf-8").read().splitlines()
    except Exception:
        return out
    for l in lines:
        try:
            d = json.loads(l)
        except Exception:
            continue
        if d.get("isMeta") or d.get("isSidechain"):
            continue
        t = ts_of(d); c = (d.get("message") or {}).get("content")
        if d.get("type") == "user":
            if isinstance(c, str):
                if real_user(c):
                    out.append((t, "user", c))
                continue
            for x in c if isinstance(c, list) else []:
                if not isinstance(x, dict):
                    continue
                if x.get("type") == "text" and real_user(x.get("text", "")):
                    out.append((t, "user", x["text"]))
                elif x.get("type") == "tool_result":
                    r = x.get("content")
                    s = r if isinstance(r, str) else "".join(y.get("text", "") for y in r or [] if isinstance(y, dict))
                    out.append((t, "result", s))
        elif d.get("type") == "assistant":
            for x in c if isinstance(c, list) else []:
                if isinstance(x, dict) and x.get("type") == "tool_use" and x.get("name") == "Bash":
                    cmd = (x.get("input") or {}).get("command", "")
                    if DECL.fullmatch(cmd):
                        out.append((t, "claude", cmd))
    return out


def field(text, k):
    m = re.search(r"(?:^|[ \t'/])" + k + r"[ \t]*[:：][ \t]*(.+?)[ \t]*(?=/[ \t]*(?:原文|やること|原文に無いこと|承認)[ \t]*[:：]|'?[ \t]*$)", text, re.M)
    return m.group(1).strip() if m else ""


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if os.path.exists(OFF):
        sys.exit(0)
    tool = d.get("tool_name", ""); ti = d.get("tool_input", {}) or {}
    c = ti.get("command", "") if tool == "Bash" else ""
    cw = re.sub(r"\d*>&\d+|&?\d*>\s*/dev/null", "", c)      # 2>&1 や >/dev/null は書き込みに数えない
    if tool == "Bash" and DECL.fullmatch(c):
        sys.exit(0)                      # 宣言のコマンドそのもの（何もしない）は通す
    if tool == "Bash" and re.search(GUARD, c) and re.search(WRITES + "|" + RUNS, c):
        block("このフック・settings.json・step_gate_off は Claude が書き換えない。")
    if tool in EDITS and re.search(GUARD, ti.get("file_path") or ""):
        block("このフック・settings.json・step_gate_off は Claude が書き換えない。")

    def free_only(paths):
        return paths and all(any(f in p.replace("~", HOME, 1) for f in FREE) for p in paths)
    if tool in EDITS:
        if free_only([ti.get("file_path") or ti.get("notebook_path") or ""]):
            sys.exit(0)
    elif tool == "Bash":
        if not re.search(RUNS, c) and not re.search(WRITES, cw):
            sys.exit(0)
        # 書き込み先をすべて拾い、全部がカード等の通してよい場所のときだけ通す
        tg = re.findall(r"(?:>>?|\btee(?:\s+-a)?)\s*(\"[^\"]+\"|'[^']+'|[^\s;&|]+)", cw)
        tg = [t.strip("'\"") for t in tg]
        if not re.search(RUNS, c) and free_only(tg) and not re.search(WRITECMD, cw):
            sys.exit(0)
    elif not tool.startswith("mcp__blender__execute"):
        sys.exit(0)
    tr = transcript(d.get("transcript_path", ""))
    users = [i for i, (t, k, s) in enumerate(tr) if k == "user"]
    last = users[-1] if users else -1
    decl = [s for t, k, s in tr[last + 1:] if k == "claude" and field(s, "原文")]
    if not decl:
        block("ユーザーの最後の発言の後に、宣言のコマンドで「原文:」を書いていない。")
    g = decl[-1]
    gen, todo, extra, ok = field(g, "原文"), field(g, "やること"), field(g, "原文に無いこと"), field(g, "承認")
    if not any(gen in s for t, k, s in tr if k in ("user", "result")):
        block("「原文:」（" + gen[:60] + "）がこの会話のユーザーの発言・ツールの結果にそのまま無い（言い換えは不可）。")
    if not todo:
        block("「やること:」が空。")
    if not extra:
        block("「原文に無いこと:」が空。無ければ「なし」と書く。")
    if extra != "なし":
        if not ok:
            block("原文に無いこと（" + extra[:80] + "）があるのに「承認:」が空。止めてユーザーに伝える。")
        # 承認は、その「原文に無いこと」を初めて宣言した後のユーザーの発言に限る
        first = next((i for i, (t, k, s) in enumerate(tr) if k == "claude" and field(s, "原文に無いこと") == extra), len(tr))
        if not any(ok in s for t, k, s in tr[first + 1:] if k == "user"):
            block("「承認:」の言葉が、この「原文に無いこと」を書いた後のユーザーの発言に無い。")
    sys.exit(0)


main()
