# shellcheck shell=bash
# herdr 自動attach: 端末を開いたら herdr の既定セッションに入る。無ければ作る。
# - 対話シェルのみ / すでに herdr 内なら何もしない（無限ループ防止）
# - 既存の tmux セッションの中では発動させない（入れ子防止）
# - SSH接続やVS Code等の埋め込み端末では発動させない（必要なら下のガードを調整）
if command -v herdr >/dev/null 2>&1 \
   && [[ $- == *i* ]] \
   && [[ -z "${TMUX:-}" ]] \
   && [[ -z "${HERDR_ENV:-}" ]] \
   && [[ -z "${SSH_CONNECTION:-}" ]] \
   && [[ "${TERM_PROGRAM:-}" != "vscode" ]]; then
  herdr
fi
