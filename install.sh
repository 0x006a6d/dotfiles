#!/usr/bin/env bash
set -euo pipefail

# このスクリプトがあるディレクトリ = dotfilesのルート
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- OS判定 ---
case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then OS=wsl; else OS=linux; fi
    ;;
  *) OS=unknown ;;
esac
echo "detected OS: $OS"

# --- 共通: symlinkヘルパ（既存ファイルは .bak に退避してから symlink）---
link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    echo "backup: $dst -> $dst.bak"
    mv "$dst" "$dst.bak"
  fi
  ln -snf "$src" "$dst"
  echo "link:   $dst -> $src"
}

# --- どの環境でも: tmux は symlink ---
link "$DOTFILES/tmux/.tmux.conf" "$HOME/.tmux.conf"

# --- どの環境でも: Claude Code の設定一式 ---
# settings.json はモデル/statusline/プラグイン有効化を含む。
# プラグインは settings.json の enabledPlugins から各マシンで自動インストールされる
link "$DOTFILES/claude/keybindings.json" "$HOME/.claude/keybindings.json"
link "$DOTFILES/claude/settings.json"    "$HOME/.claude/settings.json"
link "$DOTFILES/claude/scripts"          "$HOME/.claude/scripts"
# hooks は settings.json の PreToolUse から絶対パスで呼ばれる。
# ここで貼らないと hook がファイル不在で失敗する (fail-open にはしない方針)
link "$DOTFILES/claude/hooks"            "$HOME/.claude/hooks"

# --- mac: Karabiner はGUIが設定ファイルを書き換えるためディレクトリごと symlink ---
if [ "$OS" = mac ]; then
  link "$DOTFILES/karabiner" "$HOME/.config/karabiner"
fi

# --- どの環境でも: bin/ の実行スクリプトを ~/.local/bin に symlink ---
if [ -d "$DOTFILES/bin" ]; then
  for f in "$DOTFILES/bin/"*; do
    [ -f "$f" ] && link "$f" "$HOME/.local/bin/$(basename "$f")"
  done
fi

# --- bash: dotfilesのbashスニペットを ~/.bashrc から読み込む（冪等）---
# マーカーで囲んだブロックを ~/.bashrc に1度だけ追記する
BASHRC="$HOME/.bashrc"
MARKER_BEGIN="# >>> dotfiles bash >>>"
MARKER_END="# <<< dotfiles bash <<<"
if [ -f "$BASHRC" ] && grep -qF "$MARKER_BEGIN" "$BASHRC"; then
  echo "skip:   ~/.bashrc は既に dotfiles ブロックあり"
else
  {
    echo ""
    echo "$MARKER_BEGIN"
    echo "for f in \"$DOTFILES/bash/\"*.sh; do [ -r \"\$f\" ] && . \"\$f\"; done"
    echo "$MARKER_END"
  } >> "$BASHRC"
  echo "append: dotfiles bash ブロックを ~/.bashrc に追記"
fi

# --- git: 共有 gitconfig (delta + alias) を ~/.gitconfig から include（冪等）---
GIT_INC="$DOTFILES/git/delta.inc"
if git config --global --get-all include.path 2>/dev/null | grep -qxF "$GIT_INC"; then
  echo "skip:   ~/.gitconfig に既に git/delta.inc の include あり"
else
  git config --global --add include.path "$GIT_INC"
  echo "add:    include.path $GIT_INC を ~/.gitconfig に追加"
fi

# --- git-delta（差分ビューア）を OS ごとに導入 ---
if command -v delta >/dev/null 2>&1; then
  echo "skip:   git-delta は既に導入済み ($(delta --version))"
else
  case "$OS" in
    wsl|linux) sudo apt-get install -y git-delta || echo "warn:   git-delta 導入失敗（後続は継続）" ;;
    mac)       brew install git-delta || echo "warn:   git-delta 導入失敗（後続は継続）" ;;
    *)         echo "skip:   未対応OSのため git-delta はスキップ" ;;
  esac
fi

# --- starship（プロンプト）を OS ごとに導入 ---
if command -v starship >/dev/null 2>&1; then
  echo "skip:   starship は既に導入済み ($(starship --version | head -1))"
else
  case "$OS" in
    mac)       brew install starship || echo "warn:   starship 導入失敗（後続は継続）" ;;
    wsl|linux)
      # 既定の /usr/local/bin は sudo が要る（この箱は sudo 不可）ため
      # -b で ~/.local/bin に入れる。~/.local/bin は既に PATH に入っている想定。
      mkdir -p "$HOME/.local/bin"
      curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" \
        || echo "warn:   starship 導入失敗（後続は継続）" ;;
    *)         echo "skip:   未対応OSのため starship はスキップ" ;;
  esac
fi

# --- starship: 設定は symlink、zsh には init を追記（冪等） ---
# bash側は bash/starship.sh が ~/.bashrc 経由で読まれるので追記不要
link "$DOTFILES/starship/starship.toml" "$HOME/.config/starship.toml"

ZSHRC="$HOME/.zshrc"
if [ -f "$ZSHRC" ] && grep -qF "starship init zsh" "$ZSHRC"; then
  echo "skip:   ~/.zshrc は既に starship init あり"
else
  {
    echo ""
    echo "# starship prompt"
    echo 'if command -v starship &> /dev/null; then'
    echo '  eval "$(starship init zsh)"'
    echo 'fi'
  } >> "$ZSHRC"
  echo "append: starship init を ~/.zshrc に追記"
fi

# --- HackGen Console NF（wezterm / starship の設定がグリフを使う）---
# 実体はリポジトリに置かず公式リリースから取得する。OFL 1.1 なので同梱再配布も
# できるが、その場合 LICENSE 同梱の義務が生じるうえ 4本で 50MB を超えるため。
# 版を固定するのは、字形が端末ごとにズレると見え方が変わるため。
HACKGEN_VER="v2.10.0"
HACKGEN_FILES="HackGenConsoleNF-Regular.ttf HackGenConsoleNF-Bold.ttf HackGen35ConsoleNF-Regular.ttf HackGen35ConsoleNF-Bold.ttf"

# フォントの置き場所は OS ごとに違う。
# WSL では WezTerm が Windows アプリなので、Linux 側ではなく Windows 側へ入れる
hackgen_dest() {
  case "$OS" in
    mac)   echo "$HOME/Library/Fonts" ;;
    linux) echo "$HOME/.local/share/fonts" ;;
    wsl)
      local wu
      wu="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n')"
      [ -n "$wu" ] && echo "/mnt/c/Users/${wu}/AppData/Local/Microsoft/Windows/Fonts"
      ;;
  esac
}

# Windows はファイルを置くだけでは認識しない。レジストリへの登録が要る。
# 値名は Windows が表示に使う名前で、実測した表記に合わせてある
hackgen_register_windows() {
  local dir="$1" f name winpath
  for f in $HACKGEN_FILES; do
    case "$f" in
      HackGenConsoleNF-Regular.ttf)   name="HackGen Console NF Regular (TrueType)" ;;
      HackGenConsoleNF-Bold.ttf)      name="HackGen Console NF Bold (TrueType)" ;;
      HackGen35ConsoleNF-Regular.ttf) name="HackGen35 Console NF Regular (TrueType)" ;;
      HackGen35ConsoleNF-Bold.ttf)    name="HackGen35 Console NF Bold (TrueType)" ;;
      *) continue ;;
    esac
    # 実体が無いものを登録すると Windows 側で壊れた項目になる
    [ -f "$dir/$f" ] || continue
    winpath="$(wslpath -w "$dir/$f" 2>/dev/null)" || continue
    reg.exe add "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts" \
      /v "$name" /t REG_SZ /d "$winpath" /f >/dev/null 2>&1 \
      && echo "reg:    $name" \
      || echo "warn:   レジストリ登録に失敗: $name"
  done
}

install_hackgen() {
  local dst missing=0 f tmp
  dst="$(hackgen_dest)"
  if [ -z "$dst" ]; then
    echo "skip:   配置先を決められないため HackGen はスキップ"
    return 0
  fi

  for f in $HACKGEN_FILES; do
    [ -f "$dst/$f" ] || missing=1
  done

  if [ "$missing" -eq 0 ]; then
    echo "skip:   HackGen のファイルは配置済み ($dst)"
  else
    mkdir -p "$dst"
    tmp="$(mktemp -d)"
    if curl -fsSL --retry 3 -o "$tmp/hackgen.zip" \
        "https://github.com/yuru7/HackGen/releases/download/${HACKGEN_VER}/HackGen_NF_${HACKGEN_VER}.zip"; then
      # unzip の有無に依存したくないので python3 で取り出す
      # shellcheck disable=SC2086  # 4本のファイル名を個別の引数として渡したい
      python3 - "$tmp/hackgen.zip" "$dst" $HACKGEN_FILES <<'PYEOF'
import sys, zipfile, os, shutil
zp, dst, wanted = sys.argv[1], sys.argv[2], set(sys.argv[3:])
with zipfile.ZipFile(zp) as z:
    for n in z.namelist():
        base = os.path.basename(n)
        if base in wanted:
            with z.open(n) as src, open(os.path.join(dst, base), "wb") as out:
                shutil.copyfileobj(src, out)
            print(f"font:   {base}")
PYEOF
      [ "$OS" = linux ] && fc-cache -f "$dst" >/dev/null 2>&1 && echo "cache:  fc-cache 更新"
      echo "done:   HackGen ${HACKGEN_VER} -> $dst"
    else
      echo "warn:   HackGen の取得に失敗（後続は継続）"
    fi
    rm -rf "$tmp"
  fi

  # Windows はファイルが置いてあってもレジストリに載っていなければ認識しない。
  # 取得を飛ばした場合や、前回が登録前に中断した場合に取り残されるため、
  # ファイルの有無とは切り離して毎回確かめる（reg add /f は上書きなので冪等）
  if [ "$OS" = wsl ]; then
    hackgen_register_windows "$dst"
  fi
}

install_hackgen

# --- linux: GNOME のキーバインドを Windows 風に揃える ---
# mac の karabiner に相当するもの。WSL は Windows 側が本体なので対象外。
if [ "$OS" = linux ]; then
  "$DOTFILES/gnome/win-like.sh"
fi

# --- wezterm: 環境ごとに配置方法を変える ---
case "$OS" in
  mac|linux)
    # ネイティブアプリなので symlink でOK
    link "$DOTFILES/wezterm/wezterm.lua"  "$HOME/.config/wezterm/wezterm.lua"
    link "$DOTFILES/wezterm/keybinds.lua" "$HOME/.config/wezterm/keybinds.lua"
    ;;
  wsl)
    # WindowsアプリなのでWSLのsymlinkを辿れない → コピー
    # Windowsのユーザー名を動的に取得（ベタ書きしない）
    WIN_USER="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n')"
    WIN_WEZTERM="/mnt/c/Users/${WIN_USER}/.config/wezterm"
    if [ -n "$WIN_USER" ] && [ -d "/mnt/c/Users/${WIN_USER}" ]; then
      mkdir -p "$WIN_WEZTERM"
      cp "$DOTFILES/wezterm/wezterm.lua"  "$WIN_WEZTERM/"
      cp "$DOTFILES/wezterm/keybinds.lua" "$WIN_WEZTERM/"
      echo "copy:   wezterm -> $WIN_WEZTERM"
    else
      echo "skip:   Windowsユーザーが特定できないため wezterm はスキップ"
    fi
    ;;
  *)
    echo "skip:   未対応OSのため wezterm はスキップ"
    ;;
esac

# --- mac: システムのキーボードショートカット(Mission Control等)を復元 ---
# symbolichotkeys は cfprefsd がメモリ管理して実ファイルを書き換えるため
# symlink は不可。defaults import で流し込む方式にする。
if [ "$OS" = mac ]; then
  HOTKEYS="$DOTFILES/macos/symbolichotkeys.plist"
  if [ -f "$HOTKEYS" ]; then
    defaults import com.apple.symbolichotkeys "$HOTKEYS"
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u 2>/dev/null || true
    echo "import: com.apple.symbolichotkeys <- $HOTKEYS"
  fi
fi

echo "done."
