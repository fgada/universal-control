# Universal Control Minimal

macOS の入力を UDP で Windows へ転送する、最小構成の Universal Control 風プロトタイプです。

- macOS 側は Swift CLI
- Windows 側は .NET 8 CLI
- 同一 LAN の 1 対 1 接続前提
- 手動トグルでリモート入力を開始 / 停止
- `F18` で人が微調整したようなジッター移動を Windows 側へ送信
- リモート配信中は macOS ローカル入力を suppress

## What It Does

対応している入力は次のとおりです。

- キーボード
- Windows 側の key repeat
- modifier key
- 相対ポインタ移動
- 左 / 右 / 中クリック
- 縦スクロール
- Magic Trackpad の移動 / タップ / クリック / ドラッグ / 二本指縦スクロール

v1 では次は未対応です。

- 画面端による自動切替
- 複数端末切替
- クリップボード共有
- 水平スクロール
- トラックパッド gesture
- 接続自動発見
- 認証 / 暗号化

## Repository Layout

- `Sources/UniversalControlMinimal/`
  macOS sender
- `WindowsReceiver/`
  Windows receiver

## How It Works

macOS 側はキーボードを `IOHIDManager` で受け、押下状態を UDP で送ります。ポインタ系は `CGEventTap` で受けつつローカルイベントも suppress します。  
Windows 側は UDP を受信して `SendInput` で注入し、押下中キーは Windows の設定に合わせて key repeat します。

トグルキーは次です。

- `F18`: ジッターモード
- `F19`

`F18` はリモートモードと独立して動作し、ON 中は Windows 側へ小さな相対ポインタ移動だけを送り続けます。  
`F19` は通常のリモート入力モードです。トグルキー自体はリモートにもローカルにも流さない設計です。

## Requirements

### macOS

- macOS 13 以降
- Swift 6 toolchain
- `Input Monitoring` 権限
- `Accessibility` 権限

### Windows

- Windows 10 / 11
- .NET 8 SDK

## Build

### macOS sender

```bash
swift build
```

### Windows receiver

Windows で実行します。

```powershell
dotnet build .\WindowsReceiver\UniversalControlWindowsReceiver.csproj
```

## Run

### 1. Windows receiver を起動

```powershell
dotnet run --project .\WindowsReceiver\UniversalControlWindowsReceiver.csproj -- --listen-port 50001
```

省略時の既定ポートは `50001` です。

### 2. macOS sender を起動

```bash
swift run universal-control-minimal --target-host <WINDOWS_IP> --target-port 50001
```

`--target-port` は省略できます。
sender は起動ディレクトリの `keymap.json` を自動で読み込みます。ファイルがなければ remap は無効です。

例:

```bash
swift run universal-control-minimal --target-host 192.168.1.25
```

Command を Ctrl に寄せたい場合の例:

```bash
swift run universal-control-minimal --target-host 192.168.1.25
```

`keymap.json`:

```json
{
  "mappings": {
    "left_command": "left_control",
    "right_command": "right_control"
  }
}
```

キー名は `left_command` のような別名か、`0xE3` のような HID usage 値で書けます。

### 3. リモート入力を開始

macOS 上で次を押します。

```text
F19
```

再度 `F19` を押すとローカルへ戻ります。

### 4. ジッターモードを使う

macOS 上で次を押します。

```text
F18
```

再度 `F18` を押すと停止します。  
ジッターモードは `F19` のリモートモードと独立しており、`F19` が OFF でも Windows 側にはジッター移動だけを送り続けます。

## Permissions

macOS 側は初回実行時に次を許可してください。

- `System Settings > Privacy & Security > Input Monitoring`
- `System Settings > Privacy & Security > Accessibility`

権限がないと、入力取得やローカル suppress が正しく動きません。

## Protocol

送信パケットは little-endian の独自バイナリです。

- magic: `UCM1`
- version: `1`
- sequence: `UInt32`
- kind: `UInt8`

`kind` は次を使います。

- `1`: session
- `2`: key
- `3`: button
- `4`: pointer
- `5`: wheel
- `6`: sync

`sync` は 200ms ごとに送られます。Windows 側は 300ms を超えて途切れると stuck key / stuck button を解放し、その後 5 分までは session を維持したまま resync を待ちます。`sync` が戻れば自動復帰し、5 分を超えて戻らなければ session を放棄します。

## Operational Notes

- sender / receiver ともに固定 IP 指定の同一 LAN 前提です。
- UDP なので接続確立はありません。
- ポインタ移動だけ 1ms 単位で coalescing します。
- キー、ボタン、ホイールは即時送信します。
- Windows 側は標準権限アプリ向けです。

## Known Limitations

- `SendInput` は UIPI 制約を受けるため、管理者権限アプリや UAC 画面では効かないことがあります。
- macOS の HID 検出と event tap のタイミング差で、`F18` / `F19` の key down がローカルに一瞬見える可能性があります。
- 未対応 HID usage は Windows 側でログして無視します。
- 通信は平文 UDP で、認証も暗号化もありません。

## Troubleshooting

### macOS でイベントが来ない

- `Input Monitoring` を確認してください。
- sender を再起動してください。

### macOS でローカル入力が止まらない

- `Accessibility` 権限を確認してください。
- sender を再起動してください。

### Windows で入力されない

- Windows Firewall で UDP `50001` を許可してください。
- sender の `--target-host` が Windows の IP になっているか確認してください。
- receiver を通常権限アプリ上で試してください。

## Next Steps

今後追加しやすい拡張候補です。

- 画面端での自動切替
- 端末検出
- 認証
- 水平スクロール
- trackpad gesture
- クリップボード共有
