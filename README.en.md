# EdgeTodo · A Todo List That Lives on Your Screen Edge

[简体中文](README.md) · **English**

A minimal todo tool that lives at the edge of your screen. Most of the time it's just a small grey handle at the edge — hover it (or press `⌥⌘T`) and the panel slides out, click any blank spot to start typing, press Return and the item lands in macOS Reminders. Right-click an item to set a reminder time. It also does voice dictation: click the mic at the bottom of the panel and just talk — say "提醒我明天十点开会" and it splits into the title「开会」plus a reminder for tomorrow 10:00. Everything lives in Reminders, so it syncs to iPhone / iPad through iCloud automatically.

## Download & install

Get the latest `EdgeTodo-*.dmg` from [Releases](https://github.com/tangbonze/EdgeTodo/releases), open it, and drag `EdgeTodo.app` into Applications.

- **Requires macOS 13+** (Apple Silicon; you can also verify by building with `swiftc -target arm64-apple-macos13.0`)
- On first launch a ☑️ icon shows up in the menu bar — there's no Dock icon
- The system will ask for permission to access Reminders on first use (all reads and writes go through Reminders, synced via iCloud)
- The app is ad-hoc signed. If Gatekeeper blocks the first launch: **right-click → Open**, or run
  `xattr -dr com.apple.quarantine /Applications/EdgeTodo.app`

## Interface

- The panel is a rounded, translucent card with a 26pt radius. The window itself takes the shape of the card, so the system shadow follows the rounded corners.
- Controls are pill-shaped throughout: the list picker is a pill with a chevron, refresh in the bottom-right is a circular hover button, and due times are pills with a tinted background (orange for today, red for overdue).
- List rows have no card outline — only a 6% light overlay on hover. Opening the reminder editor first dims the panel with a 10% scrim, then stacks a card on top.
- Light and dark each stand on their own: white-tinted in light mode, black-tinted in dark mode, all text in semantic colors — no constants to change when the system appearance flips.
- macOS 26 and later uses the system glass material; earlier versions fall back to the system blur material. The two look close.

> There are no screenshots in this repo — todo items tend to leak private details. Just run the app, or use the `demoMode` switch below (the fake data has all been replaced with generic entries).

## Usage

| Action | What it does |
| --- | --- |
| Hover the grey handle at the screen edge | Panel pops out; it hides again when the mouse leaves |
| Click a blank area of the window | An input row appears at the top of the list — just type |
| Type + `Return` | Creates the todo immediately; the input row stays so you can add the next one |
| `⌥⌘T` | Show / hide the panel (focuses the input when showing) |
| Click the circle on the left | Mark as done (syncs back to Reminders) |
| **Right-click an item** | Set reminder… / Clear reminder / Move to another list / Open in Reminders / Delete |
| Click the list name at the top | Switch which Reminders list is shown |
| `ESC` | Close the reminder editor / dismiss the draft row, then hide the panel |
| Drag the grey handle | Move it up and down along the edge (remembered per display) |
| **Right-click the handle** | Dock to the left / right edge, choose which display, reset position to center |
| Menu bar icon | Show/hide, dock left/right, strip display, reset position, launch at login, quit |
| **Click the mic at the bottom** | Start dictating: creates a new todo and turns your speech into text live |
| Pause ~2.5 s while speaking / click the mic again | Stops dictation automatically and saves it as a reminder |
| Press `Return` while dictating | Saves immediately and turns the mic off |

> The panel is a **non-activating window**: once the mouse moves into the panel body (after about 0.15 s) it takes over the keyboard, so a single click starts typing — no activation click needed first. Merely passing by the edge won't steal focus.

### Multiple displays

- Every display gets its own handle, and handles can be shown on several displays at once.
- **The panel appears on whichever display you trigger it from**: slide or click a handle and the panel follows to that display. When triggered with `⌥⌘T` or the menu bar item, it follows the display the mouse is on.
- Each display remembers its own handle position, independently.
- Right-click any handle → **Displayed on**, then tick the displays you want handles on, or pick "All displays" in one go.
- Turn a display's handle off and that display never shows one — hovering there won't pop the panel either.
- You can't turn off every handle: if you'd end up with none, all of them are restored, so you never lose the only entry point.

### Type the time right into the input row

Put a natural-language expression in the title and it's split into "title + reminder time":

```
明天 9:00 交报价单     → title「交报价单」, reminder tomorrow 09:00
今晚 8点 打电话        → title「打电话」, today 20:00
下周一 10:00 例会      → next Monday 10:00
18:00 接孩子           → title「接孩子」, today 18:00 (rolls to tomorrow if already past)
后天 整理发票          → title「整理发票」, day after tomorrow 09:00 (date only defaults to 9 am)
四点 复盘              → Chinese numerals work (16:00 — adjust by hand if you meant 04:00)
三点四十 取快递        → Chinese minutes work too (15:40)
十分钟之后 回电话      → relative: now + 10 minutes
```

The parsed time shows up live on the right side of the input row; if it's wrong, right-click the item and fix it. Voice input uses the same parser: say "提醒我明天十点开会" and you get the title「开会」plus a reminder for tomorrow 10:00 — filler phrases like「提醒我」/「帮我记一下」are stripped automatically.

> **Note**: the natural-language parser is **Chinese-only** right now. The Chinese examples above are literal input; English phrases such as "tomorrow 9am" are not parsed and will stay in the title.

## Data & permissions

- It reads and writes **macOS Reminders** (EventKit), not a private database of its own — anything you change in the Reminders app or on your iPhone comes back through the `EKEventStoreChanged` notification in real time.
- The system asks for Reminders access on first launch. If you decline, you can re-enable it under `System Settings › Privacy & Security › Reminders`; the panel also has "Request access / Open System Settings" buttons.
- Dictation uses the on-device macOS model (`SFSpeechRecognizer` + `requiresOnDeviceRecognition`) and needs both Microphone and Speech Recognition permissions; audio is recognized locally.
- No data is uploaded, there's no account, and there are no network requests.

## Build it yourself

It only needs the command line tools (Xcode Command Line Tools) — no Xcode project, no third-party dependencies:

```bash
git clone https://github.com/tangbonze/EdgeTodo.git
cd EdgeTodo
./build.sh                      # produces dist/EdgeTodo.app
cp -R dist/EdgeTodo.app /Applications/   # install / overwrite
```

- `Sources/App.swift`: panel window, edge hover polling, global hotkey, menu bar, launch at login
- `Sources/PanelController.swift`: the panel UI (hand-written AppKit layout)
- `Sources/Store.swift`: EventKit read/write for Reminders
- `Sources/QuickParse.swift`: natural-language time parsing
- `Sources/VoiceInput.swift`: on-device dictation (`SFSpeechRecognizer` + on-device model)
- `AppIcon.icns`: the icon; `build.sh` handles bundling and ad-hoc signing

**Note**: every rebuild changes the binary's signature fingerprint, so macOS may treat it as a new app and ask for Reminders access again (the panel will show a permission prompt). Normal use without rebuilding is unaffected. To avoid it entirely, sign with your own Developer ID:

```bash
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" --options runtime dist/EdgeTodo.app
```

## Known limitations

- Only incomplete items are shown; completed ones live in Reminders.
- Reminder times are absolute (`EKAlarm(absoluteDate:)`); there are no relative alarms like "10 minutes before" — the context menu can be extended for that later.
- The edge handle doubles as the hover hot zone: 7pt wide, 52pt long (drag to change its vertical position), so the panel only opens when you actually rest on it — no accidental triggers. Tune the size via `edgeStripWidth` / `edgeStripHeight` in `App.swift`.
- The panel is a fixed 380×600 and appears on **the display you triggered it from** (the `⌥⌘T` hotkey and menu bar item use the display the mouse is on).
- Dictation uses the system's **on-device** model (`requiresOnDeviceRecognition`) and stays offline; it needs Microphone and Speech Recognition permissions, and the first mic click triggers the prompt. Known snag: some Bluetooth headsets deliver no audio through `AVAudioEngine`'s inputNode — switch to the built-in mic.
- On some systems the **on-device** speech model may not be fully installed, in which case the system falls back to cloud recognition. That's system behavior; the app doesn't force it either way.

## Debug switches (development)

```bash
# Preference switches (also apply to a process launched via `open`)
defaults write com.tangbonze.edgetodo showOnLaunch -bool YES   # expand the panel on launch
defaults write com.tangbonze.edgetodo demoMode     -bool YES   # fake data preview, writes nothing to Reminders
defaults write com.tangbonze.edgetodo freezeHover  -bool YES   # don't hide when the mouse leaves (handy for screenshots)
defaults write com.tangbonze.edgetodo forceDark    -bool YES   # force dark appearance
defaults write com.tangbonze.edgetodo forcePermission -bool YES # preview the "needs Reminders access" screen

# Clean up afterwards
defaults delete com.tangbonze.edgetodo showOnLaunch
```

Environment variables work too (run `dist/EdgeTodo.app/Contents/MacOS/EdgeTodo` directly):

- `EDGETODO_SHOW=1` — expand the panel on launch
- `EDGETODO_DEMO=1` — fake data
- `EDGETODO_NO_GLASS=1` — force the macOS 13–25 blur fallback, so you can check how it looks on older systems from a new one
