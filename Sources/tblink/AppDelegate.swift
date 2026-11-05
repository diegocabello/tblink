import AppKit
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Tweak these to taste. Colors are Display P3, the widest range the built-in
    // screen shows, so 1.0 means the most intense green/red/etc. it can produce.
    // The hex notes are the same channel values; in P3 they're more saturated than web hex.
    private let pieceWidth: CGFloat = 50
    private let blinkDuration: TimeInterval = 0.05 // 1/20 s
    private let restColor = NSColor(displayP3Red: 0, green: 1, blue: 0, alpha: 1) // #00ff00
    private let handColor = NSColor(displayP3Red: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let spaceColor = NSColor(displayP3Red: 1, green: 0, blue: 1, alpha: 1) // #ff00ff
    private let spaceFraction: CGFloat = 1.0 / 5.0 // space fills the bottom 1/5 of each piece
    private let backspaceColor = NSColor(displayP3Red: 0, green: 0, blue: 1, alpha: 1) // #0000ff
    private let backspaceFraction: CGFloat = 1.0 / 5.0 // backspace fills the top 1/5 of each piece
    private let doubleColor = NSColor(displayP3Red: 1, green: 1, blue: 0, alpha: 1) // #ffff00, both side strips
    private let echoColor = NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1) // #ff0000
    private let echoWidth: CGFloat = 15
    private let echoDelay: TimeInterval = 0.15 // red strips start if no key follows within this long (never after Return, Tab or arrows)
    private let echoFramesPerToggle = 2 // red strips: 2 frames on, 2 frames off
    private let echoMaxDuration: TimeInterval = 1 // ...until the next key, or 1 s, whichever comes first
    private let typoColor = NSColor(displayP3Red: 1, green: 1, blue: 0, alpha: 1) // #ffff00
    private let typoDuration: TimeInterval = 0.05 // "space then . , ? !" lights the side strips this long
    private let apostropheColor = NSColor(displayP3Red: 0, green: 1, blue: 1, alpha: 1) // #00ffff, right side strip

    private lazy var leftPiece = SidePiece(restColor: restColor)
    private lazy var rightPiece = SidePiece(restColor: restColor)
    private lazy var leftEcho = FlashStrip(color: echoColor)
    private lazy var rightEcho = FlashStrip(color: echoColor)
    private lazy var keyTap = KeyTap { [weak self] event in self?.handle(event) }
    private lazy var recorder = Recorder(hesitationThreshold: echoDelay)

    private var statusItem: NSStatusItem?
    private let toggleItem = NSMenuItem(title: "On", action: #selector(AppDelegate.toggle), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Waiting for Input Monitoring permission…", action: nil, keyEquivalent: "")
    private var retryTimer: Timer?
    private var hesitationWork: DispatchWorkItem?
    private var alarmLink: AnyObject? // CADisplayLink on macOS 14+
    private var alarmTimer: Timer?    // fallback on older macOS
    private var alarmFrame = 0
    private var lastKeyCode: Int64?
    private var lastShift = false
    private var alarmStart: CFTimeInterval = 0
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
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        setOn(true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.endSession(reason: "quit")
    }

    @objc private func willSleep() {
        recorder.endSession(reason: "sleep")
    }

    @objc private func didWake() {
        if isOn { recorder.startSession() }
    }

    // MARK: - Key handling

    private func handle(_ event: KeyEvent) {
        guard event.isDown else {
            recorder.keyUp(keyCode: event.keyCode, at: event.time)
            return
        }
        let keyCode = event.keyCode
        let shift = event.shift
        // Any key press ends the wait after space, and stops the alarm if it's going.
        hesitationWork?.cancel()
        hesitationWork = nil
        stopAlarm()
        // ⌘/Control shortcuts aren't typing: no cues, no alarm, not logged, and the
        // next key isn't treated as a double of anything before the shortcut.
        guard !event.isShortcut else {
            lastKeyCode = nil
            return
        }
        // Same key as the previous press (auto-repeat is already filtered out).
        let sameKey = keyCode == lastKeyCode
        let sameShift = shift == lastShift
        let afterSpace = lastKeyCode == KeyMap.space
        lastKeyCode = keyCode
        lastShift = shift
        guard isOn, let action = KeyMap.action(for: keyCode) else { return }

        // One kind per press. Special keys win; "double" is only for letters and numbers.
        let kind: LogKind
        if keyCode == KeyMap.apostrophe { kind = .apostrophe }
        else if keyCode == KeyMap.space { kind = .space }
        else if keyCode == KeyMap.backspace { kind = .backspace }
        else if KeyMap.enterKeys.contains(keyCode) { kind = .enter }
        else if KeyMap.isEndPunctuation(keyCode, shift: shift) { kind = .punct }
        else if KeyMap.otherKeys.contains(keyCode) { kind = .other }
        else if sameKey { kind = .double }
        else { kind = action == .left ? .left : .right }

        let isTypo = afterSpace && kind == .punct
        let isHandDouble = kind == .double
        // When a yellow side-strip cue fires, the block stays green instead of blinking pink.
        let showYellow = isTypo || isHandDouble
        switch action {
        case .left:
            if !showYellow { leftPiece.blink(handColor, for: blinkDuration) }
        case .right:
            if !showYellow { rightPiece.blink(handColor, for: blinkDuration) }
        case .space:
            leftPiece.blinkBottom(spaceColor, fraction: spaceFraction, for: blinkDuration)
            rightPiece.blinkBottom(spaceColor, fraction: spaceFraction, for: blinkDuration)
        case .backspace:
            leftPiece.blinkTop(backspaceColor, fraction: backspaceFraction, for: blinkDuration)
            rightPiece.blinkTop(backspaceColor, fraction: backspaceFraction, for: blinkDuration)
        }

        // Side-strip cues (the 15 pt strips outside the blocks).
        if isTypo {
            // "word ," / "word ." / "word ?" / "word !": almost always a typo.
            leftEcho.flash(typoColor, for: typoDuration)
            rightEcho.flash(typoColor, for: typoDuration)
        } else if isHandDouble {
            // Same letter/number key twice in a row.
            leftEcho.flash(doubleColor, for: blinkDuration)
            rightEcho.flash(doubleColor, for: blinkDuration)
        }
        if keyCode == KeyMap.apostrophe {
            rightEcho.flash(apostropheColor, for: blinkDuration)
        }

        // Hesitation: a stall after any key counts (mid-word, after space, after
        // punctuation, after backspace), except Return, Tab and navigation keys.
        let armsHesitation = !KeyMap.noHesitation.contains(keyCode)
        if armsHesitation {
            armHesitationAlarm()
        }

        var cues: [String] = []
        if isTypo { cues.append("punct-typo") }
        if isHandDouble { cues.append("double") }
        if keyCode == KeyMap.apostrophe { cues.append("apostrophe") }
        let isLetterKind = kind == .left || kind == .right || kind == .double
        recorder.keyDown(
            keyCode: keyCode,
            kind: kind,
            hand: isLetterKind ? (action == .left ? "left" : "right") : nil,
            shift: shift,
            isRepeat: !isLetterKind && sameKey && sameShift,
            cues: cues,
            armsHesitation: armsHesitation,
            at: event.time
        )
    }

    /// Hesitation alarm, armed by every key except Return, Tab and navigation: if no key follows within
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
        leftEcho.cancelFlash()
        rightEcho.cancelFlash()
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
        // Leave the strips alone if they're showing a flash instead.
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
            recorder.startSession()
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
            permissionItem.isHidden = true
            keyTap.stop()
            recorder.endSession(reason: "off")
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

    @objc private func showLogs() {
        let url = Recorder.databaseURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(Recorder.directory)
        }
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
        let logsItem = NSMenuItem(title: "Show Logs in Finder", action: #selector(showLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit tblink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}
