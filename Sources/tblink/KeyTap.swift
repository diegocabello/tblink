import CoreGraphics
import Foundation

/// Listen-only, system-wide keyDown tap. Needs Input Monitoring permission.
/// It only observes key presses; it never blocks or changes them.
final class KeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var enabled = false
    private let handler: (_ keyCode: Int64, _ shift: Bool) -> Void

    init(handler: @escaping (_ keyCode: Int64, _ shift: Bool) -> Void) {
        self.handler = handler
    }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time; afterwards it just returns the current state.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    /// Returns false if the tap couldn't be created (usually: permission not granted yet).
    func start() -> Bool {
        if let tap {
            enabled = true
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: refcon
        ) else {
            return false
        }
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = newSource
        enabled = true
        return true
    }

    func stop() {
        enabled = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever runs slow; turn it back on.
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            // First press only: skip auto-repeat while a key is held.
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            handler(event.getIntegerValueField(.keyboardEventKeycode), event.flags.contains(.maskShift))
        default:
            break
        }
    }
}

private func keyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
