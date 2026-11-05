import AppKit

/// One colored block beside the notch: a borderless panel above the menu bar
/// that ignores the mouse and shows on every Space, including over full-screen apps.
final class SidePiece {
    private let panel: NSPanel
    private let restColor: NSColor
    private var resetWork: DispatchWorkItem?
    private let bottomStrip = NSView()
    private var stripResetWork: DispatchWorkItem?
    private let topStrip = NSView()
    private var topResetWork: DispatchWorkItem?

    init(restColor: NSColor) {
        self.restColor = restColor
        panel = makeOverlayPanel(color: restColor)

        let content = NSView()
        content.wantsLayer = true
        for strip in [bottomStrip, topStrip] {
            strip.wantsLayer = true
            strip.isHidden = true
            content.addSubview(strip)
        }
        panel.contentView = content
    }

    func place(at frame: NSRect) {
        panel.setFrame(frame, display: true)
    }

    func show() { panel.orderFrontRegardless() }

    func hide() {
        resetWork?.cancel()
        stripResetWork?.cancel()
        topResetWork?.cancel()
        bottomStrip.isHidden = true
        topStrip.isHidden = true
        panel.backgroundColor = restColor
        panel.orderOut(nil)
    }

    /// Turns `color` for `duration` seconds. A new blink restarts the timer.
    func blink(_ color: NSColor, for duration: TimeInterval) {
        resetWork?.cancel()
        panel.backgroundColor = color
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.backgroundColor = self.restColor
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Fills the bottom `fraction` of the piece with `color` for `duration` seconds,
    /// leaving the rest of the piece as it is. A new blink restarts the timer.
    func blinkBottom(_ color: NSColor, fraction: CGFloat, for duration: TimeInterval) {
        stripResetWork?.cancel()
        guard let bounds = panel.contentView?.bounds else { return }
        // NSView's origin is bottom-left, so y = 0 is the bottom edge.
        bottomStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * fraction)
        bottomStrip.layer?.backgroundColor = color.cgColor
        bottomStrip.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.bottomStrip.isHidden = true
        }
        stripResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Fills the top `fraction` of the piece with `color` for `duration` seconds,
    /// leaving the rest of the piece as it is. A new blink restarts the timer.
    func blinkTop(_ color: NSColor, fraction: CGFloat, for duration: TimeInterval) {
        topResetWork?.cancel()
        guard let bounds = panel.contentView?.bounds else { return }
        let height = bounds.height * fraction
        topStrip.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        topStrip.layer?.backgroundColor = color.cgColor
        topStrip.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.topStrip.isHidden = true
        }
        topResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

/// A strip that is normally see-through and lights up when told to.
/// It stays on screen while tblink is on and switches by opacity,
/// which is cheap enough to toggle every couple of frames.
final class FlashStrip {
    private let panel: NSPanel
    private var isLit = false

    init(color: NSColor) {
        panel = makeOverlayPanel(color: color)
        panel.isOpaque = false
        panel.alphaValue = 0
    }

    func place(at frame: NSRect) {
        panel.setFrame(frame, display: false)
    }

    func show() { panel.orderFrontRegardless() }

    func hide() {
        setLit(false)
        panel.orderOut(nil)
    }

    func setLit(_ lit: Bool) {
        guard lit != isLit else { return }
        isLit = lit
        panel.alphaValue = lit ? 1 : 0
    }
}

/// A borderless panel above the menu bar that ignores the mouse and shows on
/// every Space, including over full-screen apps.
private func makeOverlayPanel(color: NSColor) -> NSPanel {
    let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .statusBar // one level above the menu bar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.isOpaque = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = color
    return panel
}

enum NotchLayout {
    /// Frames for the left and right pieces, each `width` points wide and as tall
    /// as the menu bar, flush against the camera notch. On a screen without a notch
    /// they sit at the top center with a notch-sized gap between them.
    /// The screen the pieces live on: the one with a notch, else the main screen.
    static var screen: NSScreen? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        return notched ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func frames(width: CGFloat) -> (left: NSRect, right: NSRect)? {
        guard let screen else { return nil }
        let f = screen.frame

        let height: CGFloat
        let notchLeftX: CGFloat
        let notchRightX: CGFloat
        if screen.safeAreaInsets.top > 0,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            // The auxiliary areas are the menu bar strips on either side of the notch.
            height = screen.safeAreaInsets.top
            notchLeftX = f.minX + leftArea.width
            notchRightX = f.maxX - rightArea.width
        } else {
            let fakeNotchWidth: CGFloat = 180
            height = NSStatusBar.system.thickness
            notchLeftX = f.midX - fakeNotchWidth / 2
            notchRightX = f.midX + fakeNotchWidth / 2
        }

        let y = f.maxY - height
        return (
            NSRect(x: notchLeftX - width, y: y, width: width, height: height),
            NSRect(x: notchRightX, y: y, width: width, height: height)
        )
    }
}
