import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Tweak these to taste.
    private let pieceWidth: CGFloat = 50
    private let blinkDuration: TimeInterval = 0.05 // 1/20 s
    private let restColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) // #00ff00
    private let handColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let spaceColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let spaceFraction: CGFloat = 1.0 / 5.0 // space fills the bottom 1/5 of each piece
    private let backspaceColor = NSColor.systemBlue

    private lazy var leftPiece = SidePiece(restColor: restColor)
    private lazy var rightPiece = SidePiece(restColor: restColor)
    private lazy var keyTap = KeyTap { [weak self] keyCode in self?.handle(keyCode) }

    private var statusItem: NSStatusItem?
    private let toggleItem = NSMenuItem(title: "On", action: #selector(AppDelegate.toggle), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Waiting for Input Monitoring permission…", action: nil, keyEquivalent: "")
    private var retryTimer: Timer?
    private var isOn = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutPieces),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        layoutPieces()
        setOn(true)
    }

    // MARK: - Key handling

    private func handle(_ keyCode: Int64) {
        guard isOn, let action = KeyMap.action(for: keyCode) else { return }
        switch action {
        case .left:
            leftPiece.blink(handColor, for: blinkDuration)
        case .right:
            rightPiece.blink(handColor, for: blinkDuration)
        case .space:
            leftPiece.blinkBottom(spaceColor, fraction: spaceFraction, for: blinkDuration)
            rightPiece.blinkBottom(spaceColor, fraction: spaceFraction, for: blinkDuration)
        case .backspace:
            rightPiece.blink(backspaceColor, for: blinkDuration)
        }
    }

    // MARK: - On / off

    @objc private func toggle() {
        setOn(!isOn)
    }

    private func setOn(_ on: Bool) {
        isOn = on
        toggleItem.state = on ? .on : .off
        if on {
            leftPiece.show()
            rightPiece.show()
            startTap()
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
            permissionItem.isHidden = true
            keyTap.stop()
            leftPiece.hide()
            rightPiece.hide()
        }
    }

    /// Starts the key tap, asking for permission and retrying every 2 s until it works.
    private func startTap() {
        if keyTap.start() {
            permissionItem.isHidden = true
            return
        }
        KeyTap.requestPermission()
        permissionItem.isHidden = false
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.isOn else { timer.invalidate(); return }
            if self.keyTap.start() {
                timer.invalidate()
                self.retryTimer = nil
                self.permissionItem.isHidden = true
            }
        }
    }

    // MARK: - Layout & menu

    @objc private func layoutPieces() {
        guard let frames = NotchLayout.frames(width: pieceWidth) else { return }
        leftPiece.place(at: frames.left)
        rightPiece.place(at: frames.right)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "tblink")

        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        permissionItem.isEnabled = false
        permissionItem.isHidden = true
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit tblink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
