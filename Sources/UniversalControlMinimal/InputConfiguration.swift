import Foundation

enum InputConfigurationError: Error, CustomStringConvertible {
    case unreadableFile(String, String)
    case invalidFormat(String)
    case invalidUsageToken(String)
    case invalidTargetValue(String)
    case invalidCursorSensitivity(String)
    case invalidScrollSensitivity(String)

    var description: String {
        switch self {
        case let .unreadableFile(path, reason):
            return "Failed to read input config file '\(path)': \(reason)"
        case let .invalidFormat(reason):
            return "Invalid input config file: \(reason)"
        case let .invalidUsageToken(token):
            return "Unknown key token in input config: \(token)"
        case let .invalidTargetValue(source):
            return "Invalid target value for mapping entry '\(source)'."
        case let .invalidCursorSensitivity(reason):
            return "Invalid cursor_sensitivity value: \(reason)"
        case let .invalidScrollSensitivity(reason):
            return "Invalid scroll_sensitivity value: \(reason)"
        }
    }
}

struct InputConfiguration: Sendable {
    static let defaultFileName = "input-config.json"
    static let `default` = InputConfiguration(
        overrides: [:],
        cursorSensitivity: 1.0,
        scrollSensitivity: 1.0,
        sourcePath: nil
    )

    let overrides: [UInt16: UInt16]
    let cursorSensitivity: Double
    let scrollSensitivity: Double
    let sourcePath: String?

    var hasKeyMappings: Bool {
        !overrides.isEmpty
    }

    func map(_ usage: UInt16) -> UInt16 {
        overrides[usage] ?? usage
    }

    func logLines() -> [String] {
        var lines = [
            "  cursor_sensitivity -> \(formattedCursorSensitivity)",
            "  scroll_sensitivity -> \(formattedScrollSensitivity)"
        ]
        let mappingLines = overrides.keys.sorted().compactMap { sourceUsage -> String? in
            guard let targetUsage = overrides[sourceUsage] else {
                return nil
            }

            return "  \(HIDUsageToken.displayName(for: sourceUsage)) -> \(HIDUsageToken.displayName(for: targetUsage))"
        }

        lines.append(contentsOf: mappingLines)
        return lines
    }

    static func loadDefault() throws -> InputConfiguration {
        let defaultPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(defaultFileName)
            .path

        guard FileManager.default.fileExists(atPath: defaultPath) else {
            return .default
        }

        return try loadRequired(from: defaultPath)
    }

    private var formattedCursorSensitivity: String {
        String(format: "%.3g", cursorSensitivity)
    }

    private var formattedScrollSensitivity: String {
        String(format: "%.3g", scrollSensitivity)
    }

    private static func loadRequired(from path: String) throws -> InputConfiguration {
        let expandedPath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw InputConfigurationError.unreadableFile(expandedPath, error.localizedDescription)
        }

        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw InputConfigurationError.invalidFormat(error.localizedDescription)
        }

        guard let root = rawObject as? [String: Any] else {
            throw InputConfigurationError.invalidFormat("Top-level JSON must be an object.")
        }

        let mappings: [String: Any]
        if let rawMappings = root["mappings"] {
            guard let parsedMappings = rawMappings as? [String: Any] else {
                throw InputConfigurationError.invalidFormat("Expected a 'mappings' object.")
            }
            mappings = parsedMappings
        } else {
            mappings = [:]
        }

        let cursorSensitivity = try parseSensitivity(
            from: root,
            key: "cursor_sensitivity",
            errorFactory: InputConfigurationError.invalidCursorSensitivity
        )
        let scrollSensitivity = try parseSensitivity(
            from: root,
            key: "scroll_sensitivity",
            errorFactory: InputConfigurationError.invalidScrollSensitivity
        )

        var overrides: [UInt16: UInt16] = [:]
        for (rawSource, rawTargetValue) in mappings {
            guard let sourceUsage = HIDUsageToken.parse(rawSource) else {
                throw InputConfigurationError.invalidUsageToken(rawSource)
            }

            let rawTarget: String
            switch rawTargetValue {
            case let value as String:
                rawTarget = value
            case let value as NSNumber:
                rawTarget = value.stringValue
            default:
                throw InputConfigurationError.invalidTargetValue(rawSource)
            }

            guard let targetUsage = HIDUsageToken.parse(rawTarget) else {
                throw InputConfigurationError.invalidUsageToken(rawTarget)
            }

            guard sourceUsage != targetUsage else {
                continue
            }

            overrides[sourceUsage] = targetUsage
        }

        return InputConfiguration(
            overrides: overrides,
            cursorSensitivity: cursorSensitivity,
            scrollSensitivity: scrollSensitivity,
            sourcePath: expandedPath
        )
    }

    private static func parseSensitivity(
        from root: [String: Any],
        key: String,
        errorFactory: (String) -> InputConfigurationError
    ) throws -> Double {
        guard let rawValue = root[key] else {
            return 1.0
        }

        let sensitivity: Double
        switch rawValue {
        case let value as NSNumber:
            sensitivity = value.doubleValue
        case let value as String:
            guard let parsedValue = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw errorFactory("Expected a number.")
            }
            sensitivity = parsedValue
        default:
            throw errorFactory("Expected a number.")
        }

        guard sensitivity.isFinite, sensitivity > 0 else {
            throw errorFactory("Expected a positive finite number.")
        }

        return sensitivity
    }
}

private enum HIDUsageToken {
    private static let aliases: [String: UInt16] = {
        var aliases: [String: UInt16] = [:]
        func register(_ usage: UInt16, _ names: [String]) {
            for name in names {
                aliases[normalize(name)] = usage
            }
        }

        for (offset, scalar) in "abcdefghijklmnopqrstuvwxyz".unicodeScalars.enumerated() {
            register(UInt16(0x04 + offset), [String(scalar)])
        }

        register(0x1E, ["1", "digit1"])
        register(0x1F, ["2", "digit2"])
        register(0x20, ["3", "digit3"])
        register(0x21, ["4", "digit4"])
        register(0x22, ["5", "digit5"])
        register(0x23, ["6", "digit6"])
        register(0x24, ["7", "digit7"])
        register(0x25, ["8", "digit8"])
        register(0x26, ["9", "digit9"])
        register(0x27, ["0", "digit0"])

        register(0x28, ["enter", "return"])
        register(0x29, ["escape", "esc"])
        register(0x2A, ["backspace", "delete"])
        register(0x2B, ["tab"])
        register(0x2C, ["space", "spacebar"])
        register(0x2D, ["minus", "hyphen"])
        register(0x2E, ["equal", "equals"])
        register(0x2F, ["left_bracket", "open_bracket", "lbracket"])
        register(0x30, ["right_bracket", "close_bracket", "rbracket"])
        register(0x31, ["backslash"])
        register(0x33, ["semicolon"])
        register(0x34, ["quote", "apostrophe"])
        register(0x35, ["grave", "grave_accent", "backtick"])
        register(0x36, ["comma"])
        register(0x37, ["period", "dot"])
        register(0x38, ["slash", "forward_slash"])
        register(0x39, ["caps_lock", "capslock"])
        register(0x46, ["print_screen", "printscreen"])
        register(0x47, ["scroll_lock", "scrolllock"])
        register(0x48, ["pause"])
        register(0x49, ["insert"])
        register(0x4A, ["home"])
        register(0x4B, ["page_up", "pageup"])
        register(0x4C, ["delete_forward", "forward_delete", "deleteforward"])
        register(0x4D, ["end"])
        register(0x4E, ["page_down", "pagedown"])
        register(0x4F, ["right_arrow", "arrow_right", "right"])
        register(0x50, ["left_arrow", "arrow_left", "left"])
        register(0x51, ["down_arrow", "arrow_down", "down"])
        register(0x52, ["up_arrow", "arrow_up", "up"])

        register(0x53, ["keypad_numlock", "kp_numlock", "numlock"])
        register(0x54, ["keypad_slash", "kp_slash"])
        register(0x55, ["keypad_asterisk", "kp_asterisk", "kp_star"])
        register(0x56, ["keypad_minus", "kp_minus"])
        register(0x57, ["keypad_plus", "kp_plus"])
        register(0x58, ["keypad_enter", "kp_enter"])
        register(0x59, ["keypad_1", "kp_1"])
        register(0x5A, ["keypad_2", "kp_2"])
        register(0x5B, ["keypad_3", "kp_3"])
        register(0x5C, ["keypad_4", "kp_4"])
        register(0x5D, ["keypad_5", "kp_5"])
        register(0x5E, ["keypad_6", "kp_6"])
        register(0x5F, ["keypad_7", "kp_7"])
        register(0x60, ["keypad_8", "kp_8"])
        register(0x61, ["keypad_9", "kp_9"])
        register(0x62, ["keypad_0", "kp_0"])
        register(0x63, ["keypad_period", "kp_period", "kp_dot"])
        register(0x64, ["non_us_backslash", "nonusbackslash"])
        register(0x65, ["application", "menu"])

        for functionKey in 1...12 {
            register(UInt16(0x39 + functionKey), ["f\(functionKey)"])
        }

        let extendedFunctionUsages: [(Int, UInt16)] = [
            (13, 0x68),
            (14, 0x69),
            (15, 0x6A),
            (16, 0x6B),
            (17, 0x6C),
            (18, 0x6D),
            (19, 0x6E),
            (20, 0x6F),
            (21, 0x70),
            (22, 0x71),
            (23, 0x72),
            (24, 0x73)
        ]
        for (functionKey, usage) in extendedFunctionUsages {
            register(usage, ["f\(functionKey)"])
        }

        register(0xE0, ["left_control", "left_ctrl", "lctrl"])
        register(0xE1, ["left_shift", "lshift"])
        register(0xE2, ["left_alt", "left_option", "left_opt", "lalt", "loption", "lopt"])
        register(0xE3, ["left_gui", "left_command", "left_cmd", "left_win", "left_windows", "left_meta", "lcmd", "lwin"])
        register(0xE4, ["right_control", "right_ctrl", "rctrl"])
        register(0xE5, ["right_shift", "rshift"])
        register(0xE6, ["right_alt", "right_option", "right_opt", "ralt", "roption", "ropt"])
        register(0xE7, ["right_gui", "right_command", "right_cmd", "right_win", "right_windows", "right_meta", "rcmd", "rwin"])

        return aliases
    }()

    private static let canonicalNames: [UInt16: String] = [
        0xE0: "left_control",
        0xE1: "left_shift",
        0xE2: "left_option",
        0xE3: "left_command",
        0xE4: "right_control",
        0xE5: "right_shift",
        0xE6: "right_option",
        0xE7: "right_command"
    ]

    static func parse(_ rawValue: String) -> UInt16? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let usage = parseNumeric(trimmed) {
            return usage
        }

        return aliases[normalize(trimmed)]
    }

    static func displayName(for usage: UInt16) -> String {
        canonicalNames[usage] ?? String(format: "0x%04X", Int(usage))
    }

    private static func parseNumeric(_ rawValue: String) -> UInt16? {
        if rawValue.hasPrefix("0x") || rawValue.hasPrefix("0X") {
            return UInt16(rawValue.dropFirst(2), radix: 16)
        }

        return UInt16(rawValue)
    }

    private static func normalize(_ rawValue: String) -> String {
        rawValue
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
