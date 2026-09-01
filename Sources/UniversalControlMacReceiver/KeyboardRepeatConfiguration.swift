import CoreFoundation
import Foundation

struct KeyboardRepeatConfiguration {
    let initialDelay: Duration
    let interval: Duration
    let initialDelayMilliseconds: Int
    let intervalMilliseconds: Int

    static func load() -> KeyboardRepeatConfiguration {
        // macOSのグローバル設定値はおおむね15ms単位。未設定なら他receiverと同じ値を使う。
        let initialUnits = preferenceNumber(for: "InitialKeyRepeat")?.doubleValue
        let repeatUnits = preferenceNumber(for: "KeyRepeat")?.doubleValue
        let initialMilliseconds = clampedMilliseconds(initialUnits.map { $0 * 15 }, fallback: 500)
        let intervalMilliseconds = clampedMilliseconds(repeatUnits.map { $0 * 15 }, fallback: 33)

        return KeyboardRepeatConfiguration(
            initialDelay: .milliseconds(initialMilliseconds),
            interval: .milliseconds(intervalMilliseconds),
            initialDelayMilliseconds: initialMilliseconds,
            intervalMilliseconds: intervalMilliseconds
        )
    }

    private static func preferenceNumber(for key: String) -> NSNumber? {
        CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? NSNumber
    }

    private static func clampedMilliseconds(_ value: Double?, fallback: Int) -> Int {
        guard let value, value.isFinite, value > 0 else { return fallback }
        return min(max(Int(value.rounded()), 10), 5_000)
    }
}
