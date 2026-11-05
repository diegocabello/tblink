import AppKit

/// One colored block beside the notch. The whole block can blink, and so can
/// horizontal bands inside it (bottom, top), each on its own timer.
final class SidePiece {
    private let panel: NSPanel
    private let restColor: NSColor
    private var resetWork: DispatchWorkItem?
    private let bottomBand = Band()
    private let topBand = Band()
    /// Covers the whole block, above every band, during the hesitation alarm.
    private let alarmCover = NSView()

    init(restColor: NSColor) {
        self.restColor = restColor
        panel = makeOverlayPanel(color: restColor)

        let content = NSView()
        content.wantsLayer = true
        for band in [bottomBand, topBand] {
            content.addSubview(band.view)
        }
        alarmCover.wantsLayer = true
        alarmCover.isHidden = true
        alarmCover.autoresizingMask = [.width, .height]
        content.addSubview(alarmCover)
        panel.contentView = content
    }

    /// Turns the whole block `color` (on top of everything else) or back off.
    func setAlarm(_ color: NSColor, lit: Bool) {
        if lit {
            alarmCover.frame = panel.contentView?.bounds ?? .zero
            alarmCover.layer?.backgroundColor = color.cgColor
        }
        alarmCover.isHidden = !lit
    }

    func place(at frame: NSRect) {
        panel.setFrame(frame, display: true)
    }

    func show() { panel.orderFrontRegardless() }

    func hide() {
        resetWork?.cancel()
        for band in [bottomBand, topBand] { band.clear() }
        alarmCover.isHidden = true
        panel.backgroundColor = restColor
        panel.orderOut(nil)
    }

    /// Turns the whole block `color` for `duration` seconds. A new blink restarts the timer.
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

    /// Fills the bottom `fraction` of the block.
    func blinkBottom(_ color: NSColor, fraction: CGFloat, for duration: TimeInterval) {
        bottomBand.blink(color, from: 0, to: fraction, in: panel.contentView, for: duration)
    }

    /// Fills the top `fraction` of the block.
    func blinkTop(_ color: NSColor, fraction: CGFloat, for duration: TimeInterval) {
        topBand.blink(color, from: 1 - fraction, to: 1, in: panel.contentView, for: duration)
    }
}

/// A horizontal band inside a block that flashes a color and then disappears.
private final class Band {
    let view = NSView()
    private var resetWork: DispatchWorkItem?

    init() {
        view.wantsLayer = true
        view.isHidden = true
    }

    /// `from` and `to` are fractions of the block's height, measured from the bottom.
    /// A new blink restarts the timer.
    func blink(_ color: NSColor, from: CGFloat, to: CGFloat, in container: NSView?, for duration: TimeInterval) {
        resetWork?.cancel()
        guard let bounds = container?.bounds else { return }
        // NSView's origin is bottom-left, so y = 0 is the bottom edge.
        view.frame = NSRect(x: 0, y: bounds.height * from,
                            width: bounds.width, height: bounds.height * (to - from))
        view.layer?.backgroundColor = color.cgColor
        view.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.view.isHidden = true }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func clear() {
        resetWork?.cancel()
        view.isHidden = true
    }
}

/// A strip that is normally see-through and lights up when told to: either a timed
/// flash, or switched directly (the hesitation alarm does that every couple of frames).
/// It stays on screen while tblink is on and switches by opacity,
/// which is cheap enough to toggle every couple of frames.
final class FlashStrip {
    private let panel: NSPanel
    private var isLit = false
    private var flashWork: DispatchWorkItem?

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
        cancelFlash()
        setLit(false)
        panel.orderOut(nil)
    }

    /// Lights the strip `color` for `duration` seconds. A new flash replaces the old one.
    func flash(_ color: NSColor, for duration: TimeInterval) {
        flashWork?.cancel()
        setColor(color)
        setLit(true)
        let work = DispatchWorkItem { [weak self] in
            self?.flashWork = nil
            self?.setLit(false)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func cancelFlash() {
        flashWork?.cancel()
        flashWork = nil
    }

    func setColor(_ color: NSColor) {
        panel.backgroundColor = color
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
    // Draw in Display P3 so the wide-gamut colors aren't clipped to sRGB.
    panel.colorSpace = .displayP3
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
