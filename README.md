# dotfiles

WSL / macOS / 素のLinux に対応した個人用 dotfiles。

## 構成

```
~/dotfiles/
├── install.sh          # OS判定して配置を自動化（mac/wsl/linux）
├── .gitignore
├── tmux/
│   └── .tmux.conf
├── gnome/
│   └── win-like.sh     # GNOME のキーバインドを Windows 風に揃える（linux のみ）
├── starship/
│   └── starship.toml   # プロンプト設定（starship 本体は install.sh が導入）
└── wezterm/
    ├── wezterm.lua     # target_triple でOSごとに分岐
    └── keybinds.lua
```

## セットアップ

```bash
git clone <this-repo> ~/dotfiles
cd ~/dotfiles
./install.sh
```

## 配置方法（環境ごと）

| 対象 | mac / linux | WSL |
|------|-------------|-----|
| tmux | symlink | symlink |
| starship | symlink (`~/.config/starship.toml`) | symlink |
| claude | symlink (`~/.claude/settings.json`, `scripts/`, `keybindings.json`) | symlink |
| wezterm | symlink (`~/.config/wezterm/`) | **コピー** (`/mnt/c/Users/<user>/.config/wezterm/`) |
| gnome | linux のみ `gsettings` を直接書き換え | 対象外 |

- **tmux** はsymlinkなので、`~/dotfiles/` の中を編集すれば即反映。
- **WSLのwezterm** はWindowsアプリでWSLのsymlinkを辿れないため `install.sh` でコピー配置。
  リポジトリ側 (`wezterm/wezterm.lua`) を編集 → `./install.sh` を再実行してWindowsへ反映。
  `automatically_reload_config = true` なので反映自体は自動。
- 既存ファイルは install 実行時に `*.bak` へ退避するので安全。

## gnome/win-like.sh（Windows 風キーバインド）

素の Linux + GNOME で、mac 側の `karabiner/karabiner.json` と同じ操作感にする。
`install.sh` が `OS=linux` のときだけ実行する（WSL は Windows 側が本体なので対象外）。

Linux は修飾キーの物理配置が元から Windows と同じ（Ctrl が左下、Alt+F4 で終了、
Home/End が行頭行末）なので、karabiner の Command↔Control 入替や Home/End 補正に
相当する処理は要らない。keyd/xremap のような再マップ層は使わず `gsettings` だけで足りる。

karabiner のルールとの対応:

| karabiner (mac) | GNOME での扱い |
|---|---|
| Swap Command ↔ Control | 不要（Ctrl が既に Windows 位置） |
| Cmd+Tab でアプリ切替 | Alt+Tab を `switch-windows` に移し、ウィンドウ単位で巡回させる |
| Cmd+` で IME 切替 | `switch-input-source` を Alt+` に |
| Alt+F4 で終了 | GNOME 既定のまま |
| Win+L でロック | GNOME 既定のまま |
| Win+E で Finder | `media-keys home` を Super+E に |
| Win 単独で Raycast | `overlay-key` が Super_L → Activities |
| Win+Shift+S で範囲SS | `show-screenshot-ui` に Super+Shift+S を追加 |
| Home/End, Ctrl+Home/End | 不要（Linux ネイティブで同挙動） |
| Win+矢印 スナップ | tiling-assistant 拡張が既定で割当済み |
| F5 リロード | 不要（ブラウザネイティブ） |

karabiner に無いが Windows にある分として、Win+Tab（タスクビュー）と Win+D
（デスクトップ表示）も足している。Windows には「アプリ単位の切替」自体が無いので
`switch-applications` は空にして Super+Tab をタスクビューへ渡す。

冪等なので何度実行してもよい。変更した値は `set:`、既に一致していれば `ok:` を出す。

## bin/bwsx（Bitwarden Secrets Manager）

API キー類を `.env` や `~/.zshenv` に常駐させず、必要なコマンドの実行時だけ環境変数として注入する。

```bash
bwsx run -- 'コマンド'   # マシンアカウントが読めるシークレットを注入して実行
bwsx project list        # 素の bws サブコマンドも通る
```

- 注入されたシークレットは子プロセスの環境変数になる。信頼できるコマンドにだけ渡す。シークレット名をそのまま変数名にしたくない場合は `bws run --uuids-as-keynames` で UUID 由来の名前にできる。
- `bws` 本体は同梱していない。<https://github.com/bitwarden/sdk-sm/releases> から各アーキテクチャ用を `~/.local/bin/bws` に置く。
- アクセストークンの置き場所は OS ごとに変わる。未登録なら `bwsx` が登録コマンドを表示する。

| 環境 | 保管先 | 登録方法 |
|------|--------|----------|
| mac | login keychain | `security add-generic-password -a "$USER" -s bws_token -U -w` |
| WSL | Windows 資格情報マネージャー (PasswordVault) | `bin/bws-store.ps1` を powershell.exe で実行 |
| linux | `~/.config/bws/token` (600) | ファイルに書く（平文なので端末の性質を見て判断） |

- トークンは端末ごとに別々に発行する。端末を手放したらその1本だけ revoke すればよい。
- 有効期限切れで `bwsx` が失敗したら、Web で再発行して同じ手順で上書きする。

## 依存ツール（install.sh が自動導入）

- **starship**: プロンプト。mac は brew、linux/WSL は公式インストーラで導入し、
  zsh は `~/.zshrc` に init を追記、bash は `bash/starship.sh` 経由で有効化。
- **git-delta**: git の差分ビューア。
- **Nerd Font**: starship / wezterm の設定がグリフ（  󰌾 など）を使うため必須。
  wezterm 側は HackGen Console NF を指定している（フォント自体の導入は手動）。

## 注意

- WSLでは `cmd.exe /c 'echo %USERNAME%'` でWindowsユーザー名を動的取得（ベタ書きしない）。
