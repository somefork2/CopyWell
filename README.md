# CopyWell

Clipboard manager for macOS 14+. Keyboard-first, on-device, no account required.

## Features

- **History** — everything you copy, searchable across text, links, OCR'd images, tags and source app.
- **Clipboard palette** — ⌥⌘V opens a floating panel at the cursor without stealing focus, so the paste lands where you were typing.
- **Menu bar** — the last dozen clips with search, one click to paste, no window needed.
- **Paste Stack** — queue clips and paste them in order.
- **Pinboards** — group clips you keep reusing.
- **On-device analysis** — Natural Language for type, language, entities and tags; Vision for text in screenshots. Nothing leaves the Mac.
- **Privacy first** — items marked secret by password managers are never recorded; items you mark sensitive are encrypted with a key in your login keychain; windows can be hidden from screen recordings.
- **Export** — JSON, CSV, Markdown, HTML.
- **iCloud sync** — optional, through your own private CloudKit database. A custom record zone with server change tokens, so edits and deletions both propagate. Syncs on launch, when you switch back to CopyWell, on a timer and shortly after you copy. Images and clips marked sensitive never leave the Mac.
- **Themes** — System, Light, Dark, plus Paper, Graphite, Slate and Ink.
- **Accessible** — five text sizes that scale every label and grow the rows with them.
- **Optional sounds** — off after installation; pick what plays when a clip is captured or used.
- **Rich text** — formatting is kept, so "paste as plain text" has something to strip.
- **Retention you choose** — keep the last N clips, or only the last N days, or everything. Favourites and pinboards are never dropped.
- **Screenshots with markup** — ⇧⌘9 freezes the screen; drag to select an area (or click for the whole screen), move and resize it by its handles, then mark it up with pen, line, arrow, rectangle, ellipse, highlighter, text and blur. ⏎ or ⌘C copies it and adds it to the history, ⌘S saves a PNG, and "Copy Text in Image" copies the words in it.
- **Screen recording, Loom-style** — ⇧⌘0 records an area, the whole screen, or — through the system's own picker, as video calls share a window — one window or one app: your camera in a round bubble you can drag and resize, your voice, the Mac's sound, every click shown as a burst, a 3-2-1 countdown, pause, drawing on screen that fades by itself, start over and delete. The movie is saved to Movies ▸ CopyWell, copied as a file ready to paste into a message, and opens in a review window with trimming. Every recording is listed under **Recordings** in the main window.
- **45 languages** — every language the App Store offers, switchable in Settings while the app runs.

## Keyboard shortcuts

All global shortcuts are remappable in Settings ▸ Shortcuts.

| Shortcut | Action |
|---|---|
| ⌥⌘V | Open the clipboard palette |
| ⌃⌘V | Put the previous item back on the clipboard |
| ⌃⌥⌘V | Copy the latest clip without formatting |
| ⌥⌘P | Pin the last copied item |
| ⌃⌥P | Pause / resume recording |
| ⌥⌘S | Copy the next item from the Paste Stack |
| ⇧⌘9 | Capture an area of the screen |
| ⇧⌘0 | Record the screen / stop recording |

Inside the screenshot overlay:

| Key | Action |
|---|---|
| Drag / click | Select an area / the whole screen |
| P L A R O M T B | Pen, line, arrow, rectangle, ellipse, marker, text, blur |
| ⌘Z | Undo the last mark |
| ⏎ or ⌘C | Copy and add to history |
| ⌘S | Save as PNG |
| ⌘A | Select the whole screen |
| ⎋ or right-click | Cancel |

In the main window, pinboards included: click a clip's icon or thumbnail to preview it, ⌘Y or Space for the selected row, ⏎ to paste, ⌥⏎ as plain text, ⌘D to favourite, ⌘⌫ to delete.

Inside the palette:

| Key | Action |
|---|---|
| ↑ ↓ | Move |
| ⌘1–9 | Jump to an item |
| ⏎ | Copy and return to your app |
| ⌥⏎ | Copy without formatting |
| ⌘Y | Quick Look |
| ⌘F | Focus search |
| ⌘⌫ | Delete |
| ⎋ | Close |

CopyWell adds a **CopyWell** item to the top level of Finder's right-click menu
through a Finder extension: save the selected files, copy their paths, or copy
their text contents. Enable it in System Settings ▸ General ▸ Login Items &
Extensions ▸ Finder Extensions.

CopyWell also installs Services entries (Save to CopyWell, Pin to CopyWell, Add to CopyWell Paste Stack, Copy Text in Image, Paste as Plain Text from CopyWell, Paste from CopyWell) that appear in the right-click ▸ Services menu of any app. Enable them in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services.

## Permissions

**The clipboard asks for none.** Screenshots and screen recording need the
Screen Recording permission, which macOS requires of any app that captures the
screen; CopyWell explains it and asks the first time one of them is used, and
nothing else depends on it. The camera and microphone are asked for only when
the camera bubble or voice recording is switched on — both are off by default.

It never synthesises keystrokes, so it does not need Accessibility access —
choosing a clip puts it on the clipboard and hands focus back to the app you
came from, one ⌘V away. To insert a clip without pressing anything, use
Services ▸ Paste from CopyWell, which is the mechanism macOS provides for one
app to hand text to another and requires no permission.

iCloud is used only if you turn sync on, and only in your own private database.

Recordings are written to Movies ▸ CopyWell, which is what the
`assets.movies.read-write` sandbox entitlement is for.

## Building

The App Store build comes from the Xcode project, which carries the sandbox, entitlements, signing and privacy manifest:

```bash
xcodegen generate
open CopyWell.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml` (or pick your team in Xcode) before archiving. `Products.storekit` is attached to the Run scheme so purchases can be exercised without App Store Connect.

The Swift package builds the same sources for quick type-checking, but cannot produce a signed, sandboxed bundle:

```bash
swift build
```

## Release checklist

See [docs/APP_STORE.md](docs/APP_STORE.md).

## Architecture

```
Sources/
├── App/        # Entry point, AppDelegate, coordinator that owns shortcuts and capture
├── Capture/    # Screenshot overlay and markup, screen recording (ScreenCaptureKit)
├── Core/       # Store, settings, hashing, image storage, encryption, shortcut model
├── Models/     # SwiftData models
├── Services/   # Capture, paste, categorisation, OCR, StoreKit, CloudKit, export
├── Views/      # SwiftUI views, palette panel, menu bar, settings
└── Resources/  # Info.plist, entitlements, privacy manifest, app icon
```

## License

MIT
