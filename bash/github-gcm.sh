# shellcheck shell=bash
# gh CLI に Windows Git Credential Manager のトークンを都度渡す。
# gh 自身は未認証のままにする (トークンを gh の設定へ永続化しない)。
# 資格情報キーは箱によって違う: この箱は host のみ (git:https://github.com)。
# username= 行を付けると GCM がアカウント選択待ちになり無反応になる。

_gcm_github_token() {
	printf 'protocol=https\nhost=github.com\n\n' \
		| timeout 15 git credential fill 2>/dev/null \
		| sed -n 's/^password=//p'
}

gh() {
	if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
		command gh "$@"
		return
	fi
	local tok
	tok=$(_gcm_github_token)
	if [ -z "$tok" ]; then
		echo "gh: GCM から github.com のトークンを取得できない。Windows 側で GCM のブラウザ OAuth を 1 回通すこと。" >&2
		return 1
	fi
	GH_TOKEN="$tok" command gh "$@"
}
