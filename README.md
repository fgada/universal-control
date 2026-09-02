# Universal Control Minimal

macOSの入力をUDPでmacOS / Windows / Ubuntuへ転送する、最小構成のUniversal Control風プロトタイプです。

- macOS sender / receiverはSwift CLI
- Windows receiverは.NET 8 CLI、Ubuntu receiverはC11
- 同一 LAN の最大3台のreceiverをファンクションキーで切り替え
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
- クリップボード共有
- 水平スクロール
- トラックパッド gesture
- 接続自動発見
- 認証 / 暗号化

## Repository Layout

- `Sources/UniversalControlMinimal/`
  macOS sender
- `Sources/UniversalControlMacReceiver/`
  macOS receiver
- `WindowsReceiver/`
  Windows receiver
- `LinuxReceiver/`
  Ubuntu/Linux receiver written in C

## How It Works

macOS 側はキーボードを `IOHIDManager` で受け、押下状態を UDP で送ります。ポインタ系は `CGEventTap` で受けつつローカルイベントも suppress します。  
receiverはUDPを受信し、macOSでは`CGEvent`、Windowsでは`SendInput`、Ubuntuでは`uinput`で注入します。押下中キーはreceiver側でも追跡し、key repeatします。

トグルキーは次です。

- `F13`: 1番目のreceiverを選択してリモート入力を開始
- `F14`: 2番目のreceiverを選択してリモート入力を開始
- `F15`: 3番目のreceiverを選択してリモート入力を開始
- `F18`: ジッターモード
- `F19`: リモート / ローカルモード切り替え

`F13`〜`F15`で選択できるのは、対応する順番の`--target-host`が指定されている場合だけです。同時配信はせず、選択中の1台だけへ送信します。
`F18`はリモートモードと独立して動作し、ON中はreceiver側へ小さな相対ポインタ移動だけを送り続けます。ONのまま`F13`〜`F15`で切り替えると、切り替え前のreceiverにも通常入力は送らずjitterだけを継続します。
`F19` は通常のリモート入力モードです。トグルキー自体はリモートにもローカルにも流さない設計です。

## Requirements

### macOS

- macOS 13 以降
- Swift 6 toolchain
- sender: `Input Monitoring`と`Accessibility`権限
- receiver: `Accessibility`権限

### Windows

- Windows 10 / 11
- .NET 8 SDK

### Ubuntu

- Ubuntu 22.04以降（Ubuntu 26.04を含む）
- C11 compiler
- Linux `uinput` headers
- `/dev/uinput`への書き込み権限

## Build

### macOS sender / receiver

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

macOS:

```bash
swift run universal-control-mac-receiver --listen-port 50001
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
swift run universal-control-minimal --target-host <RECEIVER_IP> --target-port 50001
```

`--target-port` は省略できます。
sender は起動ディレクトリの `input-config.json` を自動で読み込みます。ファイルがなければ remap とカーソル感度変更は無効です。
`F19` でリモートモードを有効にするたびに再読込されます。

例:

```bash
swift run universal-control-minimal --target-host 192.168.1.25
```

複数のreceiverを切り替える場合は、切り替え順に`--target-host`を指定します。

```bash
swift run universal-control-minimal \
  --target-host 192.168.1.25 \
  --target-host 192.168.1.26 \
  --target-host 192.168.1.27
```

この例では`F13`が`.25`、`F14`が`.26`、`F15`が`.27`です。押した時点でそのreceiverへのリモート入力を開始し、他のreceiverへは送信しません。

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
  },
  "slots": {
    "2": {
      "apply": false
    }
  }
}
```

トップレベルの設定は全スロットの既定値です。`slots`の`1`、`2`、`3`はそれぞれ`F13`、`F14`、`F15`に対応します。上の例では2番目のreceiverだけ`input-config.json`を適用せず、HID usageとポインタ・スクロール量をそのまま送ります。Mac receiverを2番目に指定する場合に利用できます。

スロット内で`cursor_sensitivity`、`scroll_sensitivity`、`mappings`を指定すると、そのスロットだけ上書きできます。省略した項目はトップレベル設定を継承し、空の`"mappings": {}`はremapを無効にします。

キー名は `left_command` のような別名か、`0xE3` のような HID usage 値で書けます。
日本語キーボード系の `henkan` / `muhenkan` も指定できます。
`cursor_sensitivity` の既定値は `1.0` です。`1.1` で速く、`0.9` で遅くなります。
`scroll_sensitivity` の既定値も `1.0` で、`1.1` で多く、`0.9` で少なくスクロールします。

### 3. リモート入力を開始・切り替え

1〜3番目のreceiverを直接選択するには、macOS上で`F13`、`F14`、`F15`を押します。

最後に選択したreceiverに対してリモート / ローカルを切り替える場合は次を押します。起動後まだ選択していない場合は、1番目のreceiverが対象です。

```text
F19
```

再度`F19`を押すとローカルへ戻ります。

### 4. ジッターモードを使う

macOS 上で次を押します。

```text
F18
```

再度 `F18` を押すと停止します。  
ジッターモードは`F19`のリモートモードと独立しており、`F19`がOFFでもreceiver側にはジッター移動だけを送り続けます。ジッターモード中に送信先を切り替えた場合、それまで選択したreceiverへのジッターは`F18`でOFFにするまで継続します。

## Permissions

macOS senderは初回実行時に次を許可してください。

- `System Settings > Privacy & Security > Input Monitoring`
- `System Settings > Privacy & Security > Accessibility`

権限がないと、入力取得やローカル suppress が正しく動きません。

macOS receiverは入力注入のため、次を許可してください。未許可で起動すると設定画面への許可要求を表示します。

- `System Settings > Privacy & Security > Accessibility`

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
- macOS receiverの入力注入はAccessibility権限が必要で、ログイン画面など一部の保護された画面には入力できません。
- macOS の HID 検出と event tap のタイミング差で、`F13`〜`F15` / `F18` / `F19` の key down がローカルに一瞬見える可能性があります。
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
