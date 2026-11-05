# tblink

Two yellow blocks sit on either side of the MacBook camera notch and blink as you type.

| Key | Effect |
| --- | --- |
| Left-hand key | left block blinks red |
| Right-hand key | right block blinks red |
| Space | both blink green |
| Backspace | right block blinks blue |

Each blink lasts 1/20 s. Holding a key blinks once (no auto-repeat).
Modifiers, Caps Lock, Esc and F-keys don't blink.

**Left hand:** `` ` `` 1 2 3 4 5 6, Tab Q W E R T Y, A S D F G, Z X C V B.
**Right hand:** everything else (7–0, U–P, H–L, N–/, Return, arrows, numpad…).

Keys are matched by physical position, so switching keyboard layouts doesn't change the split.
Edit `Sources/tblink/KeyMap.swift` to move keys between hands, and the constants at the top of
`Sources/tblink/AppDelegate.swift` to change colors, width (50 pt) or blink length.

## Requirements

- macOS 12 or later
- Apple's Swift toolchain: Xcode, or the Command Line Tools (`xcode-select --install`)

## Build and run

```bash
./scripts/make-app.sh
open tblink.app
```

The first launch asks for **Input Monitoring** permission
(System Settings → Privacy & Security → Input Monitoring). Turn on tblink there.
The blocks start blinking within a couple of seconds. If they don't, quit and relaunch.

A keyboard icon in the menu bar turns tblink on and off and quits it.

For quick testing you can also `swift run`. Then permission goes to your terminal app instead of tblink.

## Notes

- **Password fields:** macOS hides key presses from all other apps while Secure Input is on, so nothing blinks there.
- **Rebuilding:** the app is signed ad hoc, so macOS may treat each rebuild as a new app. If blinking stops after a rebuild, remove tblink from Input Monitoring and add it again.
- **No notch:** on a screen without a notch, the blocks sit at the top center with a 180 pt gap between them.
- tblink only listens to key presses. It never blocks, changes or records them.
