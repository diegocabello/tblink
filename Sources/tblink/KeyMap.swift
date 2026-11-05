/// What a key press should do to the indicators.
enum KeyAction {
    case left       // left-hand key
    case right      // right-hand key
    case space
    case backspace
}

/// Maps physical key codes (kVK_* values, independent of keyboard layout) to actions.
enum KeyMap {
    static let space: Int64 = 49
    static let backspace: Int64 = 51
    static let period: Int64 = 47
    static let comma: Int64 = 43

    /// Left-hand keys: ` 1-6, Tab Q W E R T Y, A S D F G, Z X C V B (and the ISO § key).
    static let leftHand: Set<Int64> = [
        50, 10,                        // ` and ISO §
        18, 19, 20, 21, 23, 22,        // 1 2 3 4 5 6
        48, 12, 13, 14, 15, 17, 16,    // Tab Q W E R T Y
        0, 1, 2, 3, 5,                 // A S D F G
        6, 7, 8, 9, 11,                // Z X C V B
    ]

    /// Keys that never blink: Esc and F1–F20.
    static let ignored: Set<Int64> = [
        53,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Everything not listed above (7-0 - =, U-P [ ] \, H-L ; ' Return, N M , . /,
    /// arrows, numpad, forward delete, Home/End/PgUp/PgDn) is a right-hand key.
    /// Modifiers (Shift, Ctrl, Option, Cmd, Fn, Caps Lock) never reach here:
    /// they arrive as flagsChanged events, not keyDown.
    static func action(for keyCode: Int64) -> KeyAction? {
        if keyCode == space { return .space }
        if keyCode == backspace { return .backspace }
        if ignored.contains(keyCode) { return nil }
        return leftHand.contains(keyCode) ? .left : .right
    }
}
