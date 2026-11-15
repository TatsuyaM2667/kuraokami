<div align="center">

<img src="assets/kuraokami.svg" width="96" alt="kuraokami icon">

# kuraokami

**軽量・高速・省電力、そしてアニメーションに全振りした GPU ターミナルエミュレーター**

本体はすべて Odin（C/C++ のソースなし）・ SDL3 + OpenGL 3.3 + FreeType ・ アイドル時 CPU 0%

*A tiny, fast, power-friendly, animation-focused GPU terminal emulator written in Odin.*

</div>

![screenshot](assets/screenshot.png)

<sub>テーマ `catppuccin-mocha` + シェーダー `builtin:aurora`。リガチャ（`->` `!=` `<=` …）、ZWJ 絵文字、国旗、日本語、ソフト折り返しを表示している様子。</sub>

---

## 目次

- [特徴](#特徴)
- [クイックスタート](#クイックスタート)
- [ビルド](#ビルド)
- [機能一覧](#機能一覧)
- [キーバインド](#キーバインド)
- [設定](#設定)
- [クイックターミナル](#クイックターミナル)
- [シェル統合と zsh プリセット](#シェル統合と-zsh-プリセット)
- [アニメーションとカスタムシェーダー](#アニメーションとカスタムシェーダー)
- [画像・動画の表示](#画像動画の表示)
- [パフォーマンス](#パフォーマンス)
- [アーキテクチャ](#アーキテクチャ)
- [テスト](#テスト)
- [既知の制限](#既知の制限)
- [ライセンスとクレジット](#ライセンスとクレジット)

---

## 特徴

| | |
|---|---|
| ⚡ **速い** | 50 MB のテキスト出力を約 0.80 秒で処理。描画は PTY 読み取りと並行して行うので、出力が詰まらない |
| 🪶 **軽い** | 単一バイナリ約 1.9 MB（シェーパーとUnicodeテーブル込み）。直接依存は SDL3・FreeType・fontconfig・libc だけ。C++ / Python / JVM は一切不使用 |
| 🔋 **省電力** | タイマーもポーリングもなし。何も起きていないときは完全にスリープ（カーソル点滅も 30 秒無操作で停止 → CPU 0）。アニメーションは動いている間だけ vsync で描画 |
| ✨ **アニメーション** | カーソルのスライドと残像、フェード点滅、スムーススクロール、タブのスライド、Ghostty 互換カスタムシェーダー |
| 🖼️ **画像・動画** | Kitty graphics protocol（`mpv --vo=kitty` で動画再生）と Sixel |
| 🇯🇵 **日本語** | IME インライン変換、全角幅、フォント自動フォールバック、カラー絵文字、書記素クラスタ |
| 🖥️ **起動時 fastfetch** | 最初のタブで fastfetch を表示してからシェルへ |
| 🐚 **zsh を快適に** | シェル統合・履歴からの入力候補・シンタックスハイライト・補完メニュー・git 対応プロンプトを内蔵（設定ゼロで使える） |
| 🪟 **ガラスのような見た目** | 既定は深い紺 `#060913` の背景を 70% 不透明で表示（色付きセルも半透明）。設定を保存すれば即座に反映 |

## クイックスタート

```sh
git clone https://github.com/TatsuyaM2667/kuraokami.git
cd kuraokami
./build.sh       # ビルド
./install.sh     # ~/.local にバイナリ・アプリランチャー(.desktop)・アイコンを導入
kuraokami        # またはアプリランチャーから「kuraokami」
```

アンインストールは `./uninstall.sh`。`PREFIX=/usr/local ./install.sh` のようにインストール先も変えられます。

### Arch Linux（AUR）

```sh
yay -S kuraokami-git        # または paru -S kuraokami-git
```

PKGBUILD は [`packaging/aur/kuraokami-git`](packaging/aur/kuraokami-git/PKGBUILD) にあります。手元でビルドする場合:

```sh
cd packaging/aur/kuraokami-git && makepkg -si
```

Odin はリポジトリ版に左右されないよう、開発に使っている公式リリース（dev-2026-08）を PKGBUILD 内で取得して使います。

### FreeBSD / OpenBSD / NetBSD

```sh
pkg install odin zig sdl3 freetype2 fontconfig pkgconf   # FreeBSD の例
./build.sh && PREFIX=/usr/local ./install.sh
```

Odin のパッケージが古い場合は [公式リリース](https://github.com/odin-lang/Odin/releases) か [ソースからのビルド](https://odin-lang.org/docs/install/) を使ってください（dev-2026-08 以降が必要）。

```sh
kuraokami -e htop     # コマンドを直接起動
kuraokami --version
```

## ビルド

### 必要なもの

| | Linux / BSD | macOS | Windows |
|---|---|---|---|
| ツール | [Odin](https://odin-lang.org/)（dev-2026-08 以降）、[Zig](https://ziglang.org/)（無ければ `cc` で代用） | Odin、Zig | Odin、Zig |
| ライブラリ | SDL3, freetype2, fontconfig, OpenGL 3.3 | Homebrew: `sdl3 freetype fontconfig` | vcpkg: `freetype`（SDL3.dll は Odin 同梱） |
| 手順 | `./build.sh` | `./build.sh` | Developer Prompt で `build.bat` |

ビルドは Odin のインストール先を一切書き換えません（パッケージ版の Odin でもそのまま使えます）。
テキストシェーパー kb_text_shape は `third_party/kbts` に同梱しており、`./lib` にビルドされます。

```sh
./build.sh          # release (-o:speed)
./build.sh debug    # デバッグビルド
```

本体はすべて Odin で書かれています。FreeType と fontconfig も Odin から直接呼び出しています（構造体レイアウトはテストで検証）。
Zig は、同梱のテキストシェーパー kb_text_shape（`third_party/kbts`）を最初に一度だけビルドするための C コンパイラ（`zig cc`）としてだけ使います。

> **注意:** 動作確認済みなのは Linux（Wayland / X11）だけです。macOS / Windows は型チェックまでしか確認していません（PR 歓迎）。

## 機能一覧

### ターミナルの基本
- xterm 互換の VT パーサー: 256 色 / TrueColor（`;` と `:` の両形式）、太字・斜体・下線・取消線・反転・dim・非表示
- 代替画面、スクロール領域、行・文字の挿入削除、DEC 罫線文字セット、タブストップ、DECSCUSR（カーソル形状）
- **リフロー**: リサイズするとソフト折り返し行を再計算（全角文字は行をまたがない、カーソル位置追従）
- **書記素クラスタ**: 結合文字（é）、ZWJ 絵文字（👨‍👩‍👧）、国旗（🇯🇵）、肌色修飾（👍🏽）
- **リガチャ**: Odin 同梱の kb_text_shape による OpenType シェーピング（`->` `=>` `!=` `===` など）
- スクロールバック（既定 10,000 行）、**スクロールバック検索**（全一致ハイライト・件数表示）
- **Kitty キーボードプロトコル**（disambiguate / イベント種別 / 全キーエスケープ / 関連テキスト）
- マウス: 文字・単語（ダブル）・行（トリプル、折り返し行ごと）選択、copy-on-select、中クリック貼り付け、Ctrl+クリックで URL / OSC 8 リンクを開く、マウスレポート（1000/1002/1003/SGR 1006）
- ブラケットペースト（貼り付け文字列中の ESC は除去）、フォーカスレポート、同期出力（2026）、DECRQM、XTVERSION、DA1/DA2、CSI 14/16/18 t

### ウィンドウ・UI
- タブと分割ペイン（新規タブ・ペインは今いるディレクトリを引き継ぐ）
- 分割境界の**マウスドラッグ**、キーボードでのリサイズ・均等化
- IME のインライン変換表示、ファイルのドラッグ&ドロップでパスを貼り付け
- 背景透過、HiDPI、フルスクリーン、ベル時のウィンドウ点滅と画面フラッシュ
- **設定のホットリロード**（保存した瞬間に反映。エラーは画面下にトースト表示）
- **コマンドパレット**（`Ctrl+Shift+P`）: すべての操作・タブ・テーマ・シェーダーをあいまい検索して実行（日本語でも英語のアクション名でも引ける）
- **長いコマンドの完了通知**: 10 秒以上かかったコマンドが終わったとき、kuraokami を見ていなければ成功 / 失敗と所要時間をデスクトップに通知
- **セッションの復元**: ウィンドウを閉じるとタブ・分割・各ペインのディレクトリを保存し、次の起動で元に戻す（シェルを全部 `exit` して終えたときは新規）
- **クイックターミナル**: [下記](#クイックターミナル)
- 巨大な貼り付けでも画面が固まらない（ペインごとの書き込みスレッド）

### シェル連携（OSC）
| OSC | 内容 |
|---|---|
| 0 / 2 | ウィンドウ・タブのタイトル |
| 4 / 104, 10 / 11 / 12 | パレットと前景・背景・カーソル色の設定と問い合わせ（nvim の背景検出に対応） |
| 7 | カレントディレクトリ（新規タブ・ペインが継承） |
| 8 | ハイパーリンク（Ctrl+クリックで開く） |
| 9 / 777 | デスクトップ通知（Linux: notify-send、macOS: osascript） |
| 52 | クリップボードへの書き込み（**読み取りはプライバシーのため拒否**） |
| 133 | プロンプト位置の記録 → Ctrl+Shift+↑/↓ でプロンプト間ジャンプ |

## キーバインド

すべて設定ファイルで変更できます（[設定](#キーバインドの変更)）。

| キー | 動作 |
|---|---|
| `Ctrl+Shift+C` / `Ctrl+Shift+V` | コピー / 貼り付け |
| `Shift+Insert` | PRIMARY 選択を貼り付け |
| `Ctrl+Shift+A` | 全選択 |
| `Ctrl+Shift+T` / `Ctrl+Shift+W` | 新規タブ / ペイン（最後ならタブ）を閉じる |
| `Ctrl+Shift+E` / `Ctrl+Shift+O` | 右に分割 / 下に分割 |
| `Ctrl+Alt+矢印` | ペイン間の移動 |
| `Ctrl+Shift+Alt+矢印` / `Ctrl+Shift+Alt+=` | 分割サイズ変更 / 均等化 |
| `Ctrl+Tab` / `Ctrl+Shift+Tab`, `Ctrl+Shift+←/→` | 次 / 前のタブ |
| `Ctrl+Shift+1`…`9` | タブ番号へ移動 |
| `Shift+PgUp/PgDn`, `Ctrl+Shift+Home/End` | スクロール |
| `Ctrl+Shift+↑/↓` | 前 / 次のプロンプトへ（OSC 133） |
| `Ctrl+Shift+F` | 検索（`Enter` 古い方へ、`Shift+Enter` 新しい方へ、`Esc` で閉じる） |
| `Ctrl+Shift+K` | スクロールバックを消去 |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | フォントサイズ 拡大 / 縮小 / 元に戻す |
| `Ctrl+Shift+,` / `Ctrl+Shift+R` | 設定ファイルを開く / 再読み込み |
| `F11` | フルスクリーン |
| `Ctrl+Shift+P` | コマンドパレット（`↑`/`↓` で選択、`Enter` で実行、`Esc` で閉じる） |
| タブバーを中クリック | タブを閉じる |

macOS では `Cmd+C` / `Cmd+V` / `Cmd+T` / `Cmd+W` / `Cmd+D` なども使えます。

## 設定

設定ファイル: `~/.config/kuraokami/config`（`$XDG_CONFIG_HOME` を優先、Windows は `%APPDATA%\kuraokami\config`）。
`Ctrl+Shift+,` で開くと、ファイルがなければサンプル入りで作られます。書式は `キー = 値` で、`#` 以降はコメントです。

```ini
theme = tokyonight
font-family = JetBrainsMono Nerd Font Mono
font-size = 12
background-opacity = 0.7
custom-shader = builtin:aurora
keybind = ctrl+shift+d=split_right
```

### 全設定項目

| キー | 既定値 | 説明 |
|---|---|---|
| `theme` | — | 組込テーマ名、または `~/.config/kuraokami/themes/<名前>` |
| `font-family` | `JetBrains Mono, JetBrainsMono Nerd Font Mono, JetBrainsMono Nerd Font, monospace` | カンマ区切りの候補リスト。実際にインストールされている最初のフォントを使う（Windows は `C:\Windows\Fonts` 内のファイル名） |
| `font-size` | `12` | ポイント |
| `font-ligatures` | `true` | リガチャの有効・無効 |
| `foreground` / `background` | `#cdd6f4` / `#060913` | 文字色 / 背景色 |
| `cursor-color` | `#cdd6f4` | カーソル色 |
| `selection-background` | `#89b4fa` | 選択範囲の背景色 |
| `selection-foreground` | `#060913` | 選択範囲の文字色（`none` で元の色のまま） |
| `palette` | — | `palette = N=#rrggbb`（N は 0〜15） |
| `background-opacity` | `0.7` | 0〜1。保存すると即座に反映 |
| `background-opacity-cells` | `true` | 色付きのセル背景も半透明にする |
| `cursor-style` | `bar` | `block` / `underline` / `bar` |
| `cursor-blink` | `true` | フェード点滅（30 秒無操作で停止） |
| `cursor-trail` | `true` | カーソルのスライドと残像 |
| `smooth-scroll` | `true` | スムーススクロール |
| `visual-bell` | `true` | ベル時の画面フラッシュ |
| `animation` | `true` | `false` ですべてのアニメーションを停止 |
| `custom-shader` | — | `builtin:aurora` / `builtin:crt` / `builtin:cursor-glow` / `.glsl` ファイルのパス |
| `custom-shader-animation` | `true` | フォーカス中は毎フレーム描画（省電力優先なら `false`） |
| `shell-integration` | `true` | zsh / bash のシェル統合（OSC 7 / 133、タイトル） |
| `shell-preset` | `true` | 内蔵 zsh プリセット（入力候補・ハイライト・補完・プロンプトなど） |
| `startup-fetch` | `true` | 起動時に fastfetch を実行 |
| `fetch-command` | `fastfetch` | 起動時に実行するコマンド |
| `command` | `$SHELL` | 起動するシェル |
| `scrollback-limit` | `10000` | スクロールバック行数 |
| `window-padding` | `24` | ペイン内の余白（px） |
| `copy-on-select` | `true` | 選択したら PRIMARY にコピー |
| `clipboard-write` | `allow` | プログラム（ssh 先も含む）が OSC 52 でクリップボードに書き込むのを許可するか（`deny` で禁止） |
| `clipboard-paste-protection` | `true` | 改行を含む貼り付けを、ブラケットペースト非対応のプログラムに送る前にもう一度確認する |
| `notify-on-command-finish-after` | `10` | この秒数以上かかったコマンドの完了を通知（`0` で無効。シェル統合が必要） |
| `restore-session` | `true` | タブ・分割・ディレクトリを保存して次回復元する |
| `quick-terminal-autohide` | `true` | クイックターミナルが他の窓に切り替わったら自動で隠れる |
| `keybind` | — | 下記参照（複数行で指定可） |

### 組込テーマ

`kuraokami`（既定の見た目） ・ `tokyonight` ・ `catppuccin-mocha` ・ `dracula` ・ `gruvbox-dark` ・ `nord` ・ `solarized-dark`

自作テーマは `~/.config/kuraokami/themes/<名前>` に、設定ファイルと同じ書式（`background`、`foreground`、`palette` など）で置きます。
`theme =` の後に書いた色指定はテーマより優先されます。

### キーバインドの変更

```ini
keybind = ctrl+shift+d=split_right   # 追加・上書き
keybind = alt+1=goto_tab:1           # 引数付きのアクション
keybind = ctrl+shift+t=unbind        # 既定のバインドを解除
keybind = clear                      # 既定のバインドを全部消す
```

修飾キー: `ctrl` `shift` `alt` `super`（`cmd` / `win` も可）。キー名は SDL のキー名に加えて `enter` `esc` `equal` `minus` `comma` `pgup` `pgdn` などが使えます。

**アクション一覧:**
`copy` `paste` `paste_selection` `select_all` `new_tab` `close_pane` `split_right` `split_down`
`focus_left` `focus_right` `focus_up` `focus_down` `next_tab` `prev_tab` `goto_tab:N`
`resize_left` `resize_right` `resize_up` `resize_down` `equalize_splits`
`scroll_page_up` `scroll_page_down` `scroll_top` `scroll_bottom` `prompt_prev` `prompt_next`
`font_inc` `font_dec` `font_reset` `open_config` `reload_config` `search` `clear_scrollback`
`toggle_fullscreen` `command_palette` `unbind`

## クイックターミナル

`kuraokami --quick` を実行するたびに、小さな浮いたターミナルが出たり隠れたりします（中のシェルはそのまま生き続けます）。
ほかの窓に切り替えると自動で隠れます（`quick-terminal-autohide = false` で無効）。

- ランチャーから: 「kuraokami Quick」、または kuraokami の右クリックメニューの「クイックターミナル」
- キー 1 つで呼びたい場合: お使いのコンポジター / ウィンドウマネージャで `kuraokami --quick` をキーに割り当ててください
  （例: River 0.4 なら `riverctl map normal Super grave spawn "kuraokami --quick"`、sway なら `bindsym $mod+grave exec kuraokami --quick`）
- Wayland ではアプリが自分で窓の位置を決められないため、置かれる位置はウィンドウマネージャ次第です（X11 では画面上部）

## シェル統合と zsh プリセット

kuraokami は zsh と bash 用のスクリプトを内蔵しています。起動時に `~/.local/share/kuraokami/shell/` へ書き出し、
zsh には `ZDOTDIR` 経由で、bash には `--rcfile` 経由で読み込ませます（Ghostty と同じ方式）。
**あなたの `~/.zshrc`（や `ZDOTDIR` の設定）はいつも通り読み込まれ、そちらの設定が優先されます。**

### シェル統合（`shell-integration = true`）
- カレントディレクトリの通知（OSC 7）→ 新しいタブ・分割が同じ場所で開く
- プロンプト位置の記録（OSC 133）→ `Ctrl+Shift+↑/↓` でプロンプト間ジャンプ
- ウィンドウ・タブのタイトルを実行中のコマンド / 現在のディレクトリにする

### zsh プリセット（`shell-preset = true`）
`.zshrc` がほぼ空でも、最初から快適に使えるようにします。

| 機能 | 内容 |
|---|---|
| 入力候補 | 履歴から続きを薄く表示。`→` / `End` / `Ctrl+F` で確定（zsh-autosuggestions を使っていればそちらを優先） |
| ハイライト | システムに zsh-syntax-highlighting があれば自動で読み込み。なければ内蔵版（存在するコマンドは緑、ないものは赤） |
| 補完 | メニュー選択、大文字小文字を区別しない、部分一致、色付き、グループ表示 |
| 履歴 | 10 万件、タブ間で共有、重複除去、スペース始まりは記録しない |
| キー | `↑`/`↓` で入力中の文字から始まる履歴を検索、`Ctrl+←/→` で単語移動、`Ctrl+Backspace` で単語削除、`Home`/`End`/`Delete`、`Ctrl+X Ctrl+E` でエディタ編集 |
| プロンプト | 2 行構成（下の例）。git ブランチと変更状態（●）、1 秒以上かかったコマンドの所要時間、失敗時の `✘ 終了コード`、ジョブ数、時刻 |
| その他 | `auto_cd`（ディレクトリ名だけで移動）、`ll` / `la` / `..` などのエイリアス、zsh の初回設定ウィザードを出さない |

```
╭─ user@host in ~/projects/kuraokami   main ●
╰─❯                                              17.0s  ✘ 1  13:22:13
```

プロンプトなどを自分の `.zshrc` で設定していれば、そちらが使われます。

## アニメーションとカスタムシェーダー

**内蔵のアニメーション:** カーソルのスライドと残像、フェード点滅、スムーススクロール（タッチパッドの細かいスクロール量にも追従）、タブのスライドと下線の移動、起動時のフェードイン、ビジュアルベル、トースト通知のスライド。

いずれも**動いている間だけ**描画し、止まったら完全にスリープします。

### カスタムシェーダー

[Ghostty](https://ghostty.org/) / shadertoy 互換の `mainImage` 形式の GLSL を読み込めます。ターミナルの描画結果が `iChannel0` に入ります。

```glsl
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 term = texture(iChannel0, uv);
    fragColor = vec4(term.rgb * (0.9 + 0.1 * sin(iTime)), term.a);
}
```

使えるユニフォーム: `iResolution` `iTime` `iTimeDelta` `iFrame` `iMouse` `iChannel0` `iCurrentCursor` `iPreviousCursor` `iCurrentCursorColor` `iPreviousCursorColor` `iTimeCursorChange`
（カーソルは `vec4(x, y, 幅, 高さ)`。y はウィンドウ下端からの上辺の位置）

内蔵: `builtin:aurora`（背景にゆらめくオーロラ）、`builtin:crt`（ブラウン管風の湾曲・走査線・色ずれ）、`builtin:cursor-glow`（カーソルが光り、移動時にパルス）。

## 画像・動画の表示

- **Kitty graphics protocol**: RGB / RGBA / PNG、直接転送・ファイル・一時ファイル・共有メモリ、zlib 圧縮、分割転送、配置・削除・z-index
  ```sh
  mpv --vo=kitty --really-quiet video.mp4   # ターミナル内で動画を再生
  kitten icat image.png
  ```
- **Sixel**: `img2sixel`、`chafa -f sixels` など

## パフォーマンス

Linux（AMD Ryzen 7 7735HS / Radeon 680M、Wayland）での実測値:

| 項目 | 結果 |
|---|---|
| 50 MB（40 万行、色・日本語混じり）の `cat` | **約 0.80 秒** |
| パーサー単体 | 約 63 MB/秒 |
| アイドル時 CPU（点滅停止後） | **0 tick / 5 秒** |
| メモリ（RSS） | 約 94 MB（大半は Mesa の GL ドライバと fontconfig のキャッシュ） |
| バイナリサイズ | 約 1.9 MB |

省電力と速さのための工夫:
- イベントを待つ間はブロックし、タイマーもポーリングもしない
- 描画時はロック中に表示範囲だけをコピーし、シェーピングと描画はロックの外で行う（PTY の読み取りを止めない）
- ASCII 専用の高速パス、シェーピング結果とグリフ番号のキャッシュ、英数字だけの語はシェーピングを省略
- 設定監視は inotify（Linux）で、待っている間は CPU を使わない

## アーキテクチャ

```
src/
├── main.odin              アプリ本体: イベントループ、タブ・分割、入力、選択、検索、アニメーション
├── term.odin              VT パーサー、画面バッファ（リングバッファ）、リフロー、書記素、Kitty キーボード、検索
├── render.odin            フォントアトラス、シェーピング結果のキャッシュ、OpenGL 描画、ポストエフェクト、内蔵シェーダー
├── font_backend.odin      FreeType / fontconfig の Odin バインディング、kb_text_shape によるシェーピング
├── png_write.odin         デバッグ用の最小 PNG 書き出し
├── graphics.odin          Kitty graphics protocol、Sixel デコーダー
├── keys.odin              キーバインド、Kitty キーボードプロトコルのエンコード
├── config.odin            設定パーサー、組込テーマ
├── width.odin             文字幅テーブル（East Asian Wide / 絵文字 / 結合文字）
├── platform_unix.odin     forkpty、Linux / macOS 固有の処理
├── platform_windows.odin  ConPTY
├── shell_integration.odin シェル統合スクリプトの展開と zsh / bash への注入
├── watch_linux.odin       inotify による設定のホットリロード
└── term_test.odin         テスト
shell/                     zsh / bash の統合スクリプトとプリセット（バイナリに埋め込み）
assets/                    アイコン、.desktop、スクリーンショット
```

- **スレッド構成:** PTY ごとに読み取りスレッドが 1 本あり、パースして端末状態を更新します。描画は UI スレッドで行い、状態のコピー中だけロックを取ります。
- **言語:** アプリはすべて Odin です。PNG の読み込みと zlib の展開も Odin の標準ライブラリ（`core:image/png`、`core:compress/zlib`）を使っています。C++ / Python / JVM には依存していません。

## テスト

```sh
odin test src -extra-linker-flags:"-L$(pwd)/lib"
```

パーサー、折り返しとスクロール、全角文字、代替画面とスクロール領域、リサイズ、リフロー、書記素クラスタ、Kitty graphics と Sixel、OSC、Kitty キーボードプロトコル、キーバインドと設定の読み込み、検索をカバーしています。

デバッグ用: 環境変数 `KURAOKAMI_SHOT=/path/out.ppm` を付けて起動すると、毎フレームを PPM 画像に書き出します（GUI の自動確認用）。

## セキュリティ

端末に表示される文字列（ssh 先の出力や、`cat` したファイルの中身）は信頼できない入力として扱います。

- **画像のファイル転送（Kitty `t=f` / `t=t`）**: 絶対パスの通常ファイルだけ（`/proc` `/sys` `/dev` は不可、400 MB まで）。読み込み後に削除する `t=t` は、一時ディレクトリ直下で名前に `tty-graphics-protocol` を含むファイルに限定
- **共有メモリ転送**: 実際のサイズを確認してから読み込む（不正なサイズでクラッシュしない）
- **上限**: 画像は 16384 px 四方まで、配置は 1000 セルまで、zlib / PNG の展開は 256 MB まで、終端のない OSC は 1 MB・DCS / APC は 64 MB で打ち切って無視
- **リンク**: 開くのは `http` `https` `ftp` `mailto` と、実行ファイルや `.desktop` ではない `file://` だけ。Ctrl を押しながらリンクに乗せると本当の行き先を画面下に表示
- **クリップボード**: 読み取り（OSC 52 `?`）は常に拒否。書き込みは `clipboard-write` で制御
- **貼り付け**: 制御文字（ESC や `^C` など）を取り除く。改行を含む貼り付けは確認してから送る
- **ドラッグ & ドロップ**: ファイル名中の制御文字（改行によるコマンド実行）を無害化
- **通知**: 1 秒に 1 件まで、未処理は 4 件まで
- **タイトル報告（`CSI 21 t`）などの応答インジェクションに使われる問い合わせ**には応答しません

## 既知の制限

- macOS / Windows は実機未検証です（型チェックは通っています）。Windows はデスクトップ通知と Kitty の共有メモリ転送に未対応です。
- 背景のぼかし（blur）は未対応です（コンポジター側のプロトコルが必要）。
- fish のシェル統合はありません（fish 自体が OSC 7 を出すので、ディレクトリ継承は動きます）。
- 英数字だけの語はシェーパーを通さないため、`www` のような英字だけのリガチャは出ません（速度優先）。
- 閉じたペインの端末状態はメモリを解放しません（読み取りスレッドとの競合を避けるため）。
- 起動時の fastfetch は Unix 系のみです。

## ライセンスとクレジット

本体のライセンスはまだ決めていません（追加予定）。

使用ライブラリ:
- [SDL3](https://libsdl.org/)（zlib License）
- [FreeType](https://freetype.org/)（FTL / GPLv2）
- [kb_text_shape](https://github.com/JimmyLefevre/kb)（zlib License）と Odin の `vendor:kb_text_shape` バインディング（BSD-3）を `third_party/kbts` に同梱
- [fontconfig](https://www.freedesktop.org/wiki/Software/fontconfig/)（MIT 系）
- [Odin 標準ライブラリ](https://odin-lang.org/)（PNG / zlib / base64 など、zlib License）

内蔵テーマの配色は [Tokyo Night](https://github.com/folke/tokyonight.nvim)、[Catppuccin](https://github.com/catppuccin/catppuccin)、[Dracula](https://draculatheme.com/)、[Gruvbox](https://github.com/morhetz/gruvbox)、[Nord](https://www.nordtheme.com/)、[Solarized](https://ethanschoonover.com/solarized/) に基づいています。
