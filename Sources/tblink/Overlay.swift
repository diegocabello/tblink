import AppKit

/// One colored block beside the notch: a borderless panel above the menu bar
/// that ignores the mouse and shows on every Space, including over full-screen apps.
final class SidePiece {
    private let panel: NSPanel
    private let restColor: NSColor
    private var resetWork: DispatchWorkItem?

    init(restColor: NSColor) {
        self.restColor = restColor
        panel = NSPanel(
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
        panel.backgroundColor = restColor
    }

    func place(at frame: NSRect) {
        panel.setFrame(frame, display: true)
    }

    func show() { panel.orderFrontRegardless() }

    func hide() {
        resetWork?.cancel()
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
}

enum NotchLayout {
    /// Frames for the left and right pieces, each `width` points wide and as tall
    /// as the menu bar, flush against the camera notch. On a screen without a notch
    /// they sit at the top center with a notch-sized gap between them.
    static func frames(width: CGFloat) -> (left: NSRect, right: NSRect)? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
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
