# shellcheck shell=bash
# tmux 自動attach: 端末を開いたら既存セッション(main)に戻る。無ければ新規作成。
# - 対話シェルのみ / すでにtmux内なら何もしない（無限ループ防止）
# - SSH接続やVS Code等の埋め込み端末では発動させない（必要なら下のガードを調整）
# - main に既に別クライアントが attach 済みのときは、そこへ相乗り（ミラー）せず
#   独立した新セッションを作る。WezTerm の Ctrl+t で新タブを増やしたときに
#   全部が同じ画面のミラーになるのを防ぐ。誰も見ていなければ従来どおり main に戻る。
if command -v tmux >/dev/null 2>&1 \
   && [[ $- == *i* ]] \
   && [[ -z "${TMUX:-}" ]] \
   && [[ -z "${SSH_CONNECTION:-}" ]] \
   && [[ "${TERM_PROGRAM:-}" != "vscode" ]]; then
  if ! tmux has-session -t main 2>/dev/null; then
    # main がまだ無い最初のタブ: main を作る
    tmux new -s main
  elif tmux list-clients -t main 2>/dev/null | grep -q .; then
    # main を既に誰かが見ている: ミラーせず独立した新セッションを作る
    # (1, 2, 3, ... の空き番号を割り当てる)
    n=1
    while tmux has-session -t "=$n" 2>/dev/null; do ((n++)); done
    tmux new -s "$n"
  else
    # main はあるが誰も見ていない (WezTerm を閉じて開き直した等): main に戻る
    tmux attach -t main
  fi
fi
