#!/usr/bin/env bash
# GNOME のキーバインドを Windows 風に揃える。
#
# 対応表は mac 側の karabiner/karabiner.json と 1 対 1 で付けてある。
# Linux は修飾キーの物理配置が元から Windows と同じ（Ctrl が左下）なので、
# karabiner の Command<->Control 入替や Home/End 補正に相当する処理は要らない。
# keyd/xremap のような再マップ層は使わず gsettings だけで完結する。
set -euo pipefail

# gsettings のエラー文言はロケールで変わる（日本語環境では「スキーマ …
# がありません」になる）。分岐に使うので英語へ固定する
export LC_ALL=C

# XDG_CURRENT_DESKTOP は ssh 経由だと空になるため判定に使えない。
# 自分の uid で gnome-shell が動いているかどうかで見る
if ! command -v gsettings >/dev/null 2>&1 || ! pgrep -u "$(id -u)" -x gnome-shell >/dev/null 2>&1; then
  echo "skip:   GNOME セッションが動いていないので キーバインド設定はスキップ"
  exit 0
fi

# ssh 経由だとセッションバスが環境に無い。ログイン中のバスがあれば拾う
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  export DBUS_SESSION_BUS_ADDRESS
fi

# gsettings get のラッパ。スキーマ/キーが無い場合だけ 2 を返す。
# それ以外の失敗（D-Bus 不通など）は 1 を返し、set -e で止める
get_key() {
  local out rc=0
  out="$(gsettings get "$1" "$2" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      "No such schema"*|"No such key"*) return 2 ;;
      *) echo "error:  gsettings get $1 $2 が失敗: $out" >&2; return 1 ;;
    esac
  fi
  printf '%s\n' "$out"
}

set_key() {
  local schema="$1" key="$2" val="$3" cur now rc=0
  cur="$(get_key "$schema" "$key")" || rc=$?
  case "$rc" in
    0) ;;
    2) echo "skip:   $key (スキーマ $schema に無い)"; return 0 ;;
    *) return 1 ;;
  esac

  if [ "$cur" = "$val" ]; then
    echo "ok:     $key = $val"
    return 0
  fi

  gsettings set "$schema" "$key" "$val"

  # D-Bus が不通だと gsettings set は終了コード 0 のまま何も書かないので、
  # 読み直して反映を確かめる
  now="$(get_key "$schema" "$key")" || return 1
  if [ "$now" != "$val" ]; then
    echo "error:  $key の書き込みが反映されていない (期待 $val / 実際 $now)" >&2
    return 1
  fi
  echo "set:    $key: $cur -> $val"
}

WM=org.gnome.desktop.wm.keybindings
SHELL_KB=org.gnome.shell.keybindings
MEDIA=org.gnome.settings-daemon.plugins.media-keys

# Alt+Tab は全ウィンドウをフラットに巡回する（Windows 流）。
# GNOME 既定の switch-applications はアプリ単位に畳む macOS 流なので外す。
set_key "$WM" switch-applications          "@as []"
set_key "$WM" switch-applications-backward "@as []"
set_key "$WM" switch-windows               "['<Alt>Tab']"
set_key "$WM" switch-windows-backward      "['<Shift><Alt>Tab']"

# Win+Tab でタスクビュー。Windows にアプリ単位の切替は無いので Super+Tab を明け渡す
set_key "$SHELL_KB" toggle-overview        "['<Super>Tab']"

# switch-group（同一アプリ内のウィンドウ巡回。Windows には無い概念）は
# Above_Tab を握っている。Above_Tab は「Tab の上のキー」の意味で US 配列では
# grave と同じ物理キーなので、Alt+` を IME に使うには Alt 側を外す必要がある。
# 表記が違うだけで同じキーなので、文字列一致の衝突確認では見落とす
set_key "$WM" switch-group                 "['<Super>Above_Tab']"
set_key "$WM" switch-group-backward        "['<Shift><Super>Above_Tab']"

# Alt+` で IME(mozc) トグル。karabiner の「Cmd+` で IME 切替」と同じ指の位置
set_key "$WM" switch-input-source          "['<Alt>grave']"
set_key "$WM" switch-input-source-backward "['<Shift><Alt>grave']"

# Win+E でファイルマネージャ（karabiner の Win+E → Finder に対応）
set_key "$MEDIA" home                      "['<Super>e']"

# Win+Shift+S で範囲スクリーンショット。単体 Print も残す
set_key "$SHELL_KB" show-screenshot-ui     "['Print', '<Shift><Super>s']"

# Win+D でデスクトップ表示
set_key "$WM" show-desktop                 "['<Super>d']"
