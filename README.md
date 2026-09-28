# Universal Control Minimal

macOSの入力をUDPでmacOS / Windowsへ転送する、最小構成のUniversal Control風プロトタイプです。

- macOS sender / receiverはSwift CLI
- Windows receiverは.NET 8 CLI
- 同一 LAN の最大3台のreceiverをファンクションキーで切り替え
- 手動トグルでリモート入力を開始 / 停止
- `F18`で人が微調整したようなジッター移動をreceiver側へ送信
- `F16`でsenderのクリップボードテキストをreceiverのフォーカス位置へ貼り付け
- `F17`でsenderのマイク音声をreceiverのChrome拡張へ送り、Web会議アプリのマイクとして使う
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
- テンキー（数字、演算子、Enter、Num Lock / Clear）
- Magic Mouse / Magic Trackpad のジェスチャー（macOS receiverのみ）

v1 では次は未対応です。

- 画面端による自動切替
- 水平スクロール
- Windows receiverでのMagic Mouse / Magic Trackpadジェスチャー
- 接続自動発見
- 認証 / 暗号化

## Repository Layout

- `Sources/UniversalControlMinimal/`
  macOS sender
- `Sources/UniversalControlMacReceiver/`
  macOS receiver
- `WindowsReceiver/`
  Windows receiver
- `ChromeExtension/`
  マイク受信用Chrome拡張（MV3）

## How It Works

macOS 側はキーボードを `IOHIDManager` で受け、押下状態を UDP で送ります。ポインタ系は `CGEventTap` で受けつつローカルイベントも suppress します。  
receiverはUDPを受信し、macOSでは`CGEvent`、Windowsでは`SendInput`で注入します。押下中キーはreceiver側でも追跡し、key repeatします。

トグルキーは次です。

- `F13`: 1番目のreceiverを選択してリモート入力を開始
- `F14`: 2番目のreceiverを選択してリモート入力を開始
- `F15`: 3番目のreceiverを選択してリモート入力を開始
- `F16`: senderのクリップボードテキストを選択中receiverのフォーカス位置へ貼り付け
- `F18`: ジッターモード
- `F19`: リモート / ローカルモード切り替え

`F13`〜`F15`で選択できるのは、対応する順番の`--target-host`が指定されている場合だけです。同時配信はせず、選択中の1台だけへ送信します。
`F18`はリモートモードと独立して動作し、選択中のスロットごとにON/OFFを保持します。ON中のスロットにはreceiver側へ小さな相対ポインタ移動だけを送り続け、`F13`〜`F15`で別のスロットへ切り替えても、そのスロットのジッターは自動ではONになりません。
`F19` は通常のリモート入力モードです。トグルキー自体はリモートにもローカルにも流さない設計です。
`F17`は`--audio-token`付きで起動した場合だけ有効です。詳しくは「6. マイクを使う」を参照してください。
`F16`はリモートモードのON/OFFに関係なく動作します。receiver側のクリップボードにテキストをセットしてから`Cmd+V`（macOS）/ `Ctrl+V`（Windows）を送るため、receiverのクリップボードは送ったテキストで上書きされます。Windowsでは改行をCRLFに変換します。UTF-8で60 KiBを超えるテキストは送信しません。

## Requirements

### macOS

- macOS 13 以降
- Swift 6 toolchain
- sender: `Input Monitoring`と`Accessibility`権限
- receiver: `Accessibility`権限

### Windows

- Windows 10 / 11
- .NET 8 SDK

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
      "cursor_sensitivity": 1.0,
      "scroll_sensitivity": 1.0,
      "mappings": {
        "globe": "kana_abc_toggle"
      }
    }
  }
}
```

トップレベルの設定は全スロットの既定値です。`slots`の`1`、`2`、`3`はそれぞれ`F13`、`F14`、`F15`に対応します。上の例では2番目のMac receiverだけ感度を既定値に戻し、Globeをかな/ABC切り替えにします。

スロット内で`cursor_sensitivity`、`scroll_sensitivity`、`mappings`を指定すると、そのスロットだけ上書きできます。省略した項目はトップレベル設定を継承し、空の`"mappings": {}`はremapを無効にします。

キー名は `left_command` のような別名か、`0xE3` のような HID usage 値で書けます。
日本語キーボード系の `henkan` / `muhenkan`、Mac receiver用の `kana_abc_toggle` も指定できます。
`cursor_sensitivity` の既定値は `1.0` です。`1.1` で速く、`0.9` で遅くなります。
`scroll_sensitivity` の既定値も `1.0` で、`1.1` で多く、`0.9` で少なくスクロールします。

### 3. リモート入力を開始・切り替え

1〜3番目のreceiverを直接選択するには、macOS上で`F13`、`F14`、`F15`を押します。

最後に選択したreceiverに対してリモート / ローカルを切り替える場合は次を押します。起動後まだ選択していない場合は、1番目のreceiverが対象です。

```text
F19
```

再度`F19`を押すとローカルへ戻ります。

### 4. senderのクリップボードテキストを入力する

入力先のreceiverを選択し、receiver側でテキスト入力欄へフォーカスを合わせてから、macOS senderで次を押します。

```text
F16
```

senderのクリップボードにあるテキストが、receiverのクリップボードを変更せずにフォーカス位置へ直接入力されます。この操作はリモートモードがOFFでも使えます。

### 5. ジッターモードを使う

macOS 上で次を押します。

```text
F18
```

再度 `F18` を押すと、選択中のスロットのジッターだけを停止します。
ジッターモードは`F19`のリモートモードと独立しており、`F19`がOFFでもONにしたスロットのreceiver側にはジッター移動だけを送り続けます。ジッターのON/OFFはスロットごとに保持されるため、送信先を切り替えても切り替え先では自動的にONになりません。

### 6. マイクを使う（Chrome拡張）

senderのマイク音声を、receiver PCのChromeで開いたWeb会議アプリ（Teams / Meet / Zoom web など）のマイクとして使えます。receiver側に必要なのはChrome拡張だけで、ネイティブreceiverは不要です。

```text
sender: AVAudioEngine → 48kHz mono PCM16 / 20ms → WebSocketサーバ (--audio-port, 既定 50002)
receiver: 拡張のservice worker (WebSocketクライアント) → content script → ページのMAIN world
          → getUserMedia / enumerateDevices をフックして仮想マイク「Universal Control Mic」を返す
```

1. senderを`--audio-token`付きで起動します。トークンは十分に長いランダム文字列にしてください。

   ```bash
   swift run universal-control-minimal --target-host 192.168.1.25 --audio-token "$(openssl rand -hex 16)"
   ```

2. receiver PCのChromeで`chrome://extensions`を開き、デベロッパーモードで`ChromeExtension/`を「パッケージ化されていない拡張機能を読み込む」から追加します。
3. 拡張のポップアップで、senderのIP・ポート・トークンを設定します。
4. 会議アプリのマイク設定で「Universal Control Mic」を選びます。マイクを選べないアプリでは、ポップアップで「すべてのマイクを置き換える」を選んでからページを再読み込みしてください。
5. 送りたいreceiverを`F13`〜`F15`で選択してから`F17`を押すとマイク送信を開始し、もう一度`F17`で停止します。

- マイクはONにした時点で選択していたスロットに固定されます。その後`F13`〜`F15`でキーボード / マウスの送信先を切り替えても、マイクの送信先は変わりません。
- 拡張の接続元IPアドレスと`--target-host`を照合して、どのスロットの拡張かを判定します。`--target-host`にホスト名を指定した場合は名前解決して照合します。
- 拡張は、ページが仮想マイクを使っている間だけsenderに接続します。マイクOFFの間は無音を流します。
- `--audio-voice-processing`を付けると、macOSの音声処理（ノイズ抑制 / AGC）を有効にします。有効中は他のアプリの音量が下がることがあります。
- receiverのスピーカー音をsenderのマイクが拾うと、会議の相手にエコーが聞こえます。ヘッドホンを使ってください。

## Permissions

macOS senderは初回実行時に次を許可してください。

- `System Settings > Privacy & Security > Input Monitoring`
- `System Settings > Privacy & Security > Accessibility`
- `System Settings > Privacy & Security > Microphone`（`F17`を使う場合。ターミナルから起動した場合はターミナルアプリに許可します）

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
- `7`: text（UTF-8、最大60 KiB）
- `8`: gesture（シリアライズしたmacOS Quartzイベント、最大60 KiB）

### マイク（WebSocket）

マイク音声は上記のUDPとは別に、senderのWebSocketサーバ（`--audio-port`）から送ります。

- 接続時、拡張は`{"type":"hello","version":1,"token":"..."}`を送ります。`Origin`が`chrome-extension://`で始まらない接続は拒否します。
- senderの応答:
  - `{"type":"welcome","slot":1,"mic":false,...}`：接続成功。`slot`は1〜3
  - `{"type":"error","reason":"auth"}`：トークン不一致
  - `{"type":"error","reason":"unknown-host","address":"..."}`：接続元IPに一致する`--target-host`がない
- マイクのON/OFFは`{"type":"mic","active":true}`で通知します。service workerを維持するため、15秒ごとに`{"type":"ping"}`も送ります。
- 音声はbinaryフレームで送ります。`"UCA1"` / version `1` / codec `1`（PCM s16le 48kHz mono） / reserved `UInt16` / sequence `UInt32` / payload（960サンプル = 20ms）
- 送信が約0.5秒分詰まった接続にはフレームを捨てます。

`button` payloadはボタン番号、down/up、クリック回数です。receiverは旧形式のクリック回数なしpayloadもシングルクリックとして受理します。Windows receiverはクリック回数をOS側で判定するため、3番目の値を使用しません。

`sync`は200msごとに送られます。receiver側は300msを超えて途切れるとstuck key / stuck buttonを解放し、その後5分まではsessionを維持したままresyncを待ちます。`sync`が戻れば自動復帰し、5分を超えて戻らなければsessionを放棄します。

## Operational Notes

- sender / receiver ともに固定 IP 指定の同一 LAN 前提です。
- UDP なので接続確立はありません。
- ポインタ移動だけ 1ms 単位で coalescing します。
- キー、ボタン、ホイールは即時送信します。
- Windows 側は標準権限アプリ向けです。

## Known Limitations

- `SendInput` は UIPI 制約を受けるため、管理者権限アプリや UAC 画面では効かないことがあります。
- macOS receiverの入力注入はAccessibility権限が必要で、ログイン画面など一部の保護された画面には入力できません。
- macOS の HID 検出と event tap のタイミング差で、`F13`〜`F16` / `F18` / `F19` の key down がローカルに一瞬見える可能性があります。
- 未対応HID usageはreceiver側でログして無視します。
- 通信は平文 UDP で、認証も暗号化もありません。
- マイク音声のWebSocketはトークン認証のみで、暗号化はありません。信頼できるLANで使ってください。
- 仮想マイクはページの`getUserMedia`をフックする方式のため、ページのスクリプトより先に拡張が注入されない環境（拡張の読み込み前に開いていたタブなど）では、ページの再読み込みが必要です。

## Troubleshooting

### macOS でイベントが来ない

- `Input Monitoring` を確認してください。
- sender を再起動してください。

### macOS でローカル入力が止まらない

- `Accessibility` 権限を確認してください。
- sender を再起動してください。

### Chrome拡張のマイクがつながらない

- 拡張のポップアップに表示される状態を確認してください。「sender から見たアドレス」が`--target-host`と一致している必要があります。
- 「接続テスト」でsenderへの接続だけを確認できます。
- macOSのファイアウォールで、senderへのTCP `50002`の着信を許可してください。
- 会議アプリで音が出ない場合は、senderのログに`Mic client connected`と`Mic streaming enabled`が出ているか確認してください。

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
