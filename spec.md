Swift なら、最初はこれで行くのが良いです。

**`IOHIDManager` で keyboard / mouse / trackpad 系の HID 値を受ける。**
`IOHIDManager` は列挙した HID デバイスからの input value callback を登録でき、matching を複数条件で設定できます。値は `IOHIDValueGetIntegerValue` で整数として読めます。([Apple Developer][1])

`CGEventTap` は後段の「境界越えでローカル入力を止める」「イベントを書き換える」には便利ですが、Apple の説明でも low-level user input event stream の観測・改変向けです。まず受信基盤は `IOHIDManager`、必要なら後で `CGEventTap` を足すのがきれいです。グローバルに keyboard / mouse / trackpad を監視するには Input Monitoring 権限も要ります。([Apple Developer][2])

下のコードは、まず **Universal Control の土台**として十分な最小実装です。

* キーボード down / up
* modifier 変化
* relative X/Y
* wheel
* button

トラックパッド固有ジェスチャはまだ扱いません。
まずこれで低遅延パイプラインを作るのが正解です。

---

## 最小実装例

```swift
import Foundation
import IOKit.hid

final class HIDInputReceiver {
    private var manager: IOHIDManager!
    private let queue = DispatchQueue(label: "hid.receiver.queue", qos: .userInteractive)

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]

        let mouseMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
        ]

        // Magic Trackpad 系は device usage が mouse 扱いで見えることもあるので、
        // 最初は pointer 系を広めに受ける方が実運用で楽。
        let pointerMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer
        ]

        let matches: [CFDictionary] = [
            keyboardMatch as CFDictionary,
            mouseMatch as CFDictionary,
            pointerMatch as CFDictionary
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HIDInputReceiver>.fromOpaque(context).takeUnretainedValue()
            me.handleDeviceConnected(device)
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<HIDInputReceiver>.fromOpaque(context).takeUnretainedValue()
            me.handleDeviceRemoved(device)
        }, selfPtr)

        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let me = Unmanaged<HIDInputReceiver>.fromOpaque(context).takeUnretainedValue()
            me.handleInputValue(value)
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            fputs("IOHIDManagerOpen failed: \(openResult)\n", stderr)
            return
        }

        print("HIDInputReceiver started")
    }

    func run() {
        queue.async {
            self.start()
            CFRunLoopRun()
        }
    }

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString)
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString)

        print("Connected:",
              product ?? "unknown" as CFTypeRef,
              "vendor:", vendorID ?? "?" as CFTypeRef,
              "product:", productID ?? "?" as CFTypeRef)
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
        print("Removed:", product ?? "unknown" as CFTypeRef)
    }

    private func handleInputValue(_ value: IOHIDValue) {
        guard let element = IOHIDValueGetElement(value) else { return }
        let device = IOHIDElementGetDevice(element)

        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let timestamp = IOHIDValueGetTimeStamp(value)

        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

        switch usagePage {
        case UInt32(kHIDPage_KeyboardOrKeypad):
            handleKeyboard(product: product, usage: usage, value: intValue, timestamp: timestamp)

        case UInt32(kHIDPage_Button):
            handleButton(product: product, usage: usage, value: intValue, timestamp: timestamp)

        case UInt32(kHIDPage_GenericDesktop):
            handleGenericDesktop(product: product, usage: usage, value: intValue, timestamp: timestamp)

        default:
            break
        }
    }

    private func handleKeyboard(product: String, usage: UInt32, value: CFIndex, timestamp: UInt64) {
        let isDown = value != 0
        print("[KBD] product=\(product) usage=\(usage) \(isDown ? "down" : "up") ts=\(timestamp)")
        // ここで独自バイナリイベントへ変換して送る
        // send(.key(usage: UInt16(usage), isDown: isDown, ts: timestamp))
    }

    private func handleButton(product: String, usage: UInt32, value: CFIndex, timestamp: UInt64) {
        let isDown = value != 0
        print("[BTN] product=\(product) button=\(usage) \(isDown ? "down" : "up") ts=\(timestamp)")
        // send(.button(button: UInt8(usage), isDown: isDown, ts: timestamp))
    }

    private func handleGenericDesktop(product: String, usage: UInt32, value: CFIndex, timestamp: UInt64) {
        switch usage {
        case UInt32(kHIDUsage_GD_X):
            print("[PTR] product=\(product) dx=\(value) ts=\(timestamp)")
            // send(.pointerDeltaX(Int16(clamping: value), ts: timestamp))

        case UInt32(kHIDUsage_GD_Y):
            print("[PTR] product=\(product) dy=\(value) ts=\(timestamp)")
            // send(.pointerDeltaY(Int16(clamping: value), ts: timestamp))

        case UInt32(kHIDUsage_GD_Wheel):
            print("[WHL] product=\(product) wheel=\(value) ts=\(timestamp)")
            // send(.wheel(Int16(clamping: value), ts: timestamp))

        default:
            break
        }
    }
}

// 起動
let receiver = HIDInputReceiver()
receiver.run()

dispatchMain()
```

---

## まず押さえるポイント

### 1. matching は 1 個ではなく複数にする

`IOHIDManagerSetDeviceMatchingMultiple` を使って keyboard / mouse / pointer を並べるのが扱いやすいです。これは Apple の `IOHIDManager` ドキュメントでも提供されています。([Apple Developer][3])

### 2. callback はメインスレッドに置かない

低遅延化したいなら、上のように **専用 queue + run loop** で回すのがよいです。
UI スレッドに混ぜるとすぐ jitter が増えます。

### 3. キーは usage ベースで持つ

文字ではなく **HID usage** をそのまま送るのがよいです。
レイアウト依存を後段に逃がせます。キーボード usage page は `kHIDPage_KeyboardOrKeypad` です。([Apple Developer][4])

### 4. マウス移動は coalesce 前提

`dx`, `dy` はそのまま全部転送せず、**1〜4ms 窓で合成**すると実効レイテンシが安定します。
キー down/up は絶対に落とさず、ポインタ移動だけ古いものを捨てます。

---

## 次に入れると良い改善

### 修飾キーの正規化

modifier は keyboard usage として来るので、送信前に state を持って差分だけ送ると軽くなります。

```swift
struct ModifierState: OptionSet {
    let rawValue: UInt8
    static let leftControl  = ModifierState(rawValue: 1 << 0)
    static let leftShift    = ModifierState(rawValue: 1 << 1)
    static let leftOption   = ModifierState(rawValue: 1 << 2)
    static let leftCommand  = ModifierState(rawValue: 1 << 3)
    static let rightControl = ModifierState(rawValue: 1 << 4)
    static let rightShift   = ModifierState(rawValue: 1 << 5)
    static let rightOption  = ModifierState(rawValue: 1 << 6)
    static let rightCommand = ModifierState(rawValue: 1 << 7)
}
```

### Apple デバイスだけを識別したい

接続時に `vendorID`, `productID`, `product name` を見てフィルタできます。
Magic Keyboard / Magic Trackpad の判定は product 名ベースから始めて、あとで product ID を固定化するのが楽です。

### 受信イベントのバイナリ化

JSON は遅いです。最初からこんな感じに寄せるのがおすすめです。

```swift
enum PacketType: UInt8 {
    case keyDown = 1
    case keyUp = 2
    case buttonDown = 3
    case buttonUp = 4
    case move = 5
    case wheel = 6
}
```

---

## トラックパッドについての現実的な話

Magic Trackpad を **“完全に”** 再現したくなると難しくなります。
公開 API で安定して扱いやすいのは、まず相対移動・ボタン・スクロールの範囲です。
AppKit の `NSEvent` は swipe や magnify などを表現できますが、Universal Control の土台を作る段階では後回しでいいです。`NSEvent` 自体はイベント種別ごとに利用可能な情報が変わることが Apple により説明されています。([Apple Developer][5])

---

## これで次にやること

次の段階はこの順が良いです。

1. 上の `IOHIDManager` 版で **usage / dx / dy / wheel / button** をログ出し
2. そのまま UDP で別プロセスへ転送
3. キーだけ reliable、ポインタだけ latest-wins
4. その後に `CGEventTap` を入れて「境界越え時はローカル消費」を追加

必要なら次に、**この受信コードをそのまま Swift Package / macOS CLI プロジェクト構成にした版**と、**送信用の軽量バイナリプロトコル**まで続けて書きます。

[1]: https://developer.apple.com/documentation/iokit/1438367-iohidmanagerregisterinputvalueca "https://developer.apple.com/documentation/iokit/1438367-iohidmanagerregisterinputvalueca"
[2]: https://developer.apple.com/documentation/coregraphics/quartz-event-services "https://developer.apple.com/documentation/coregraphics/quartz-event-services"
[3]: https://developer.apple.com/documentation/iokit/1438387-iohidmanagersetdevicematchingmul "https://developer.apple.com/documentation/iokit/1438387-iohidmanagersetdevicematchingmul"
[4]: https://developer.apple.com/documentation/kernel/1641368-anonymous/khidpage_keyboardorkeypad?changes=__6 "https://developer.apple.com/documentation/kernel/1641368-anonymous/khidpage_keyboardorkeypad?changes=__6"
[5]: https://developer.apple.com/documentation/appkit/nsevent "https://developer.apple.com/documentation/appkit/nsevent"
