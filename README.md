# dotfiles

WSL / macOS / 素のLinux に対応した個人用 dotfiles。

## 構成

```
~/dotfiles/
├── install.sh          # OS判定して配置を自動化（mac/wsl/linux）
├── .gitignore
├── tmux/
│   └── .tmux.conf
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

- **tmux** はsymlinkなので、`~/dotfiles/` の中を編集すれば即反映。
- **WSLのwezterm** はWindowsアプリでWSLのsymlinkを辿れないため `install.sh` でコピー配置。
  リポジトリ側 (`wezterm/wezterm.lua`) を編集 → `./install.sh` を再実行してWindowsへ反映。
  `automatically_reload_config = true` なので反映自体は自動。
- 既存ファイルは install 実行時に `*.bak` へ退避するので安全。

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
