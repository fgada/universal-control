# Universal Control Minimal

macOSの入力をUDPでWindows / Ubuntuへ転送する、最小構成のUniversal Control風プロトタイプです。

- macOS 側は Swift CLI
- Windows側は.NET 8 CLI、Ubuntu側はC11
- 同一 LAN の 1 対 1 接続前提
- 手動トグルでリモート入力を開始 / 停止
- `F18`で人が微調整したようなジッター移動をreceiver側へ送信
- リモート配信中は macOS ローカル入力を suppress

## What It Does

対応している入力は次のとおりです。

- キーボード
- receiver側のkey repeat
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
- `LinuxReceiver/`
  Ubuntu/Linux receiver written in C

## How It Works

macOS 側はキーボードを `IOHIDManager` で受け、押下状態を UDP で送ります。ポインタ系は `CGEventTap` で受けつつローカルイベントも suppress します。  
receiverはUDPを受信し、Windowsでは`SendInput`、Ubuntuでは`uinput`で注入します。押下中キーはreceiver側でも追跡し、key repeatします。

トグルキーは次です。

- `F18`: ジッターモード
- `F19`

`F18`はリモートモードと独立して動作し、ON中はreceiver側へ小さな相対ポインタ移動だけを送り続けます。
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

### Ubuntu

- Ubuntu 22.04以降（Ubuntu 26.04を含む）
- C11 compiler
- Linux `uinput` headers
- `/dev/uinput`への書き込み権限

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

### Ubuntu receiver

外部ライブラリは使用しません。C標準ライブラリ、POSIX API、Linux標準ヘッダーだけでビルドします。

```bash
make -C LinuxReceiver
```


## Run

### 1. receiverを起動

Windows:

```powershell
dotnet run --project .\WindowsReceiver\UniversalControlWindowsReceiver.csproj -- --listen-port 50001
```

Ubuntu:

```bash
sudo modprobe uinput # 再起動時のみ
./LinuxReceiver/universal-control-receiver --listen-port 50001
```

`/dev/uinput`を開けない場合は、Ubuntu側でモジュールと権限を設定してください。設定後は再ログインが必要です。

```bash
sudo modprobe uinput
echo 'KERNEL=="uinput", GROUP=="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/99-uinput.rules
sudo usermod -aG input "$USER"
sudo udevadm control --reload-rules
sudo udevadm trigger
```

省略時の既定ポートは `50001` です。

### 2. macOS sender を起動

```bash
swift run universal-control-minimal --target-host <WINDOWS_IP> --target-port 50001
```

`--target-port` は省略できます。
sender は起動ディレクトリの `input-config.json` を自動で読み込みます。ファイルがなければ remap とカーソル感度変更は無効です。
`F19` でリモートモードを有効にするたびに再読込されます。

例:

```bash
swift run universal-control-minimal --target-host 192.168.1.25
```

Command を Ctrl に寄せたい場合の例:

```bash
swift run universal-control-minimal --target-host 192.168.1.25
```

`input-config.json`:

```json
{
  "cursor_sensitivity": 1.1,
  "scroll_sensitivity": 0.9,
  "mappings": {
    "left_command": "left_control",
    "right_command": "right_control"
  }
}
```

キー名は `left_command` のような別名か、`0xE3` のような HID usage 値で書けます。
日本語キーボード系の `henkan` / `muhenkan` も指定できます。
`cursor_sensitivity` の既定値は `1.0` です。`1.1` で速く、`0.9` で遅くなります。
`scroll_sensitivity` の既定値も `1.0` で、`1.1` で多く、`0.9` で少なくスクロールします。

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
ジッターモードは`F19`のリモートモードと独立しており、`F19`がOFFでもreceiver側にはジッター移動だけを送り続けます。

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

`sync`は200msごとに送られます。receiver側は300msを超えて途切れるとstuck key / stuck buttonを解放し、その後5分まではsessionを維持したままresyncを待ちます。`sync`が戻れば自動復帰し、5分を超えて戻らなければsessionを放棄します。

## Operational Notes

- sender / receiver ともに固定 IP 指定の同一 LAN 前提です。
- UDP なので接続確立はありません。
- ポインタ移動だけ 1ms 単位で coalescing します。
- キー、ボタン、ホイールは即時送信します。
- Windows 側は標準権限アプリ向けです。
- Ubuntu receiverは外部ライブラリに依存せず、入力注入にカーネルの`uinput`を使用します。

## Known Limitations

- `SendInput` は UIPI 制約を受けるため、管理者権限アプリや UAC 画面では効かないことがあります。
- macOS の HID 検出と event tap のタイミング差で、`F18` / `F19` の key down がローカルに一瞬見える可能性があります。
- 未対応HID usageはreceiver側でログして無視します。
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

### Ubuntu で入力されない

- `ls -l /dev/uinput`でデバイスと権限を確認してください。
- `id`で現在のログインセッションに`input`グループが反映されているか確認してください。
- firewallを使用している場合はUDP `50001`を許可してください。

## Next Steps

今後追加しやすい拡張候補です。

- 画面端での自動切替
- 端末検出
- 認証
- 水平スクロール
- trackpad gesture
- クリップボード共有
