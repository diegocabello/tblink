# tblink

Two green (#00ff00) blocks sit on either side of the MacBook camera notch and blink as you type.

| Key | Effect |
| --- | --- |
| Left-hand key | left block blinks magenta (#ff00ff) |
| Right-hand key | right block blinks magenta |
| Same letter/number key twice in a row (e.g. the ll in "literally") | on the second press the 15 pt side strips blink yellow (#ffff00); the block doesn't blink pink |
| Space | bottom 1/5 of both blocks blinks magenta |
| `.` `,` `?` or `!` right after a space ("word ,") | the 15 pt side strips blink yellow (#ffff00); the block doesn't blink pink |
| Apostrophe `'` | the 15 pt strip right of the right block blinks cyan (#00ffff) |
| Backspace | top 1/5 of both blocks blinks blue (#0000ff) |
| Any pause of 0.15 s after a key (mid-word, after space, punctuation or backspace) | hesitation alarm: both blocks turn **solid** red (#ff0000) while the 15 pt side strips blink red 2 frames on, 2 frames off until your next key or for at most 1 s. Never after Return, Enter, Tab, arrows or Home/End/Page keys |

Colors are pure channels in **Display P3**, the screen's full wide-color range, so they're more intense than the same hex codes on the web (sRGB).

Each blink lasts 1/20 s. Holding a key blinks once (no auto-repeat).
Modifiers, Caps Lock, Esc and F-keys don't blink.

**Left hand:** `` ` `` 1 2 3 4 5 6, Tab Q W E R T Y, A S D F G, Z X C V B.
**Right hand:** everything else (7–0, U–P, H–L, N–/, Return, arrows, numpad…).

Keys are matched by physical position, so switching keyboard layouts doesn't change the split.
Edit `Sources/tblink/KeyMap.swift` to move keys between hands, and the constants at the top of
`Sources/tblink/AppDelegate.swift` to change colors, width (50 pt) or blink length.

## Logging

While tblink is on, it records **one row per key press** to a local SQLite file:

```
~/Library/Application Support/tblink/tblink.sqlite
```

Menu bar icon → **Show Logs in Finder** opens it. Nothing leaves your Mac.

It **never records which key you pressed**, only its kind:
`left`, `right`, `double` (2nd+ press of the same letter/number), `apostrophe`, `space`,
`punct` (`.` `,` `?` `!`), `backspace`, `enter`, `other` (Tab, arrows, Home/End/Page keys, forward delete).
⌘/Control shortcuts, Esc and F-keys aren't logged.

| Table | Columns |
| --- | --- |
| `sessions` | `started_at`, `ended_at`, `end_reason` (off, sleep, quit) |
| `events` | `t` (seconds since session start), `kind`, `hand` (for left/right/double), `shift`, `is_repeat` (a special key repeated: `''`, `..`, double space), `hold_ms`, `gap_after_ms` (empty if over 6 s), `alarm` (hesitation alarm went off after it), `cues` (`double`, `punct-typo`, `apostrophe`) |
| `markers` | `secure-input-on` / `-off`: password fields hide keys, so gaps there aren't hesitation |

Try it:

```bash
sqlite3 ~/Library/Application\ Support/tblink/tblink.sqlite "SELECT kind, COUNT(*), ROUND(AVG(gap_after_ms)) FROM events GROUP BY kind"
```

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
