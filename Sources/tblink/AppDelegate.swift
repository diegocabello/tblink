import AppKit
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Tweak these to taste.
    private let pieceWidth: CGFloat = 50
    private let blinkDuration: TimeInterval = 0.05 // 1/20 s
    private let restColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) // #00ff00
    private let handColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let spaceColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let spaceFraction: CGFloat = 1.0 / 5.0 // space fills the bottom 1/5 of each piece
    private let backspaceColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) // #ff0000
    private let backspaceFraction: CGFloat = 1.0 / 5.0 // backspace fills the top 1/5 of each piece
    private let doubleColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let doubleBand: (from: CGFloat, to: CGFloat) = (1.0 / 5.0, 4.0 / 5.0) // middle 3/5 of the block
    private let echoColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) // #ff0000
    private let echoWidth: CGFloat = 15
    private let echoDelay: TimeInterval = 0.15 // red strips start if no key follows space or backspace within this long
    private let echoFramesPerToggle = 2 // red strips: 2 frames on, 2 frames off
    private let echoMaxDuration: TimeInterval = 3 // ...until the next key, or 3 s, whichever comes first
    private let typoColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1) // #ffff00
    private let typoDuration: TimeInterval = 0.15 // "space then . or ," lights the side strips this long

    private lazy var leftPiece = SidePiece(restColor: restColor)
    private lazy var rightPiece = SidePiece(restColor: restColor)
    private lazy var leftEcho = FlashStrip(color: echoColor)
    private lazy var rightEcho = FlashStrip(color: echoColor)
    private lazy var keyTap = KeyTap { [weak self] keyCode in self?.handle(keyCode) }

    private var statusItem: NSStatusItem?
    private let toggleItem = NSMenuItem(title: "On", action: #selector(AppDelegate.toggle), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Waiting for Input Monitoring permission…", action: nil, keyEquivalent: "")
    private var retryTimer: Timer?
    private var hesitationWork: DispatchWorkItem?
    private var alarmLink: AnyObject? // CADisplayLink on macOS 14+
    private var alarmTimer: Timer?    // fallback on older macOS
    private var alarmFrame = 0
    private var lastKeyCode: Int64?
    private var alarmStart: CFTimeInterval = 0
    private var typoWork: DispatchWorkItem?
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
        // Any key press ends the wait after space, and stops the alarm if it's going.
        hesitationWork?.cancel()
        hesitationWork = nil
        stopAlarm()
        // Same key as the previous press (auto-repeat is already filtered out).
        let isDouble = keyCode == lastKeyCode
        let afterSpace = lastKeyCode == KeyMap.space
        lastKeyCode = keyCode
        guard isOn, let action = KeyMap.action(for: keyCode) else { return }
        // "word ," or "word ." : punctuation right after a space is almost always a typo.
        if afterSpace && (keyCode == KeyMap.period || keyCode == KeyMap.comma) {
            flashTypoCue()
        }
        switch action {
        case .left:
            blinkHand(leftPiece, isDouble: isDouble)
        case .right:
            blinkHand(rightPiece, isDouble: isDouble)
        case .space:
            leftPiece.blinkBottom(spaceColor, fraction: spaceFraction, for: blinkDuration)
            rightPiece.blinkBottom(spaceColor, fraction: spaceFraction, for: blinkDuration)
            armHesitationAlarm()
        case .backspace:
            leftPiece.blinkTop(backspaceColor, fraction: backspaceFraction, for: blinkDuration)
            rightPiece.blinkTop(backspaceColor, fraction: backspaceFraction, for: blinkDuration)
            armHesitationAlarm()
        }
    }

    /// A hand key blinks the whole block on its side. The second press of a double
    /// instead blinks only the middle band, on both blocks, leaving their top and
    /// bottom fifths green.
    private func blinkHand(_ piece: SidePiece, isDouble: Bool) {
        if isDouble {
            for side in [leftPiece, rightPiece] {
                side.endBlink() // an earlier press may still be lighting the whole block
                side.blinkMiddle(doubleColor, from: doubleBand.from, to: doubleBand.to, for: blinkDuration)
            }
        } else {
            piece.blink(handColor, for: blinkDuration)
        }
    }

    /// Hesitation alarm, armed by space and backspace: if no key follows within
    /// echoDelay, the red strips blink until the next key press (or for at most
    /// echoMaxDuration).
    private func armHesitationAlarm() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOn else { return }
            self.hesitationWork = nil
            self.startAlarm()
        }
        hesitationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + echoDelay, execute: work)
    }

    // MARK: - Hesitation alarm

    /// Blinks the red strips: `echoFramesPerToggle` frames on, the same number off,
    /// synced to the screen's refresh, until the next key press or `echoMaxDuration`.
    private func startAlarm() {
        stopAlarm()
        typoWork?.cancel()
        typoWork = nil
        setEchoColor(echoColor)
        alarmFrame = 0
        alarmStart = CACurrentMediaTime()
        setEchoLit(true)
        if #available(macOS 14.0, *), let screen = NotchLayout.screen {
            let link = screen.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            alarmLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.alarmTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            alarmTimer = timer
        }
    }

    private var alarmRunning: Bool { alarmLink != nil || alarmTimer != nil }

    private func stopAlarm() {
        // Leave the strips alone if they're showing the typo cue instead.
        guard alarmRunning else { return }
        if #available(macOS 14.0, *) {
            (alarmLink as? CADisplayLink)?.invalidate()
        }
        alarmLink = nil
        alarmTimer?.invalidate()
        alarmTimer = nil
        setEchoLit(false)
    }

    @objc private func displayLinkTick(_ link: AnyObject) {
        alarmTick()
    }

    /// Called once per frame while the alarm runs.
    private func alarmTick() {
        // You've stopped typing (finished a message, walked away): give up quietly.
        if CACurrentMediaTime() - alarmStart >= echoMaxDuration {
            stopAlarm()
            return
        }
        alarmFrame += 1
        setEchoLit((alarmFrame / echoFramesPerToggle) % 2 == 0)
    }

    /// Lights the side strips solid yellow for typoDuration. Typing on doesn't cut it short.
    private func flashTypoCue() {
        stopAlarm()
        typoWork?.cancel()
        setEchoColor(typoColor)
        setEchoLit(true)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.typoWork = nil
            self.setEchoLit(false)
            self.setEchoColor(self.echoColor)
        }
        typoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typoDuration, execute: work)
    }

    private func setEchoColor(_ color: NSColor) {
        leftEcho.setColor(color)
        rightEcho.setColor(color)
    }

    private func setEchoLit(_ lit: Bool) {
        leftEcho.setLit(lit)
        rightEcho.setLit(lit)
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
            leftEcho.show()
            rightEcho.show()
            startTap()
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
            permissionItem.isHidden = true
            keyTap.stop()
            hesitationWork?.cancel()
            hesitationWork = nil
            stopAlarm()
            leftPiece.hide()
            rightPiece.hide()
            leftEcho.hide()
            rightEcho.hide()
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
        // Red strips sit on the outer edges: left of the left block, right of the right block.
        leftEcho.place(at: NSRect(x: frames.left.minX - echoWidth, y: frames.left.minY,
                                  width: echoWidth, height: frames.left.height))
        rightEcho.place(at: NSRect(x: frames.right.maxX, y: frames.right.minY,
                                   width: echoWidth, height: frames.right.height))
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
