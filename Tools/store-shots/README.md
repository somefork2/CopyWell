# Store shots

Marketing screenshots for the Mac App Store listing — ten frames, 2880×1800,
in one look: a near-black ground lit by two coloured glows, the header centred
at the top, and the scene on a Mac screen with wallpaper and a menu bar.

The finished set, in listing order, is in `docs/screenshots/store/`:

| # | Frame | Made by |
|---|---|---|
| 01 | Palette over a mail — ⌥⌘V | `shots.html?n=1` |
| 02 | Screenshots with markup | `FeatureShots.swift` |
| 03 | Screen recording | `FeatureShots.swift` |
| 04 | Search | `shots.html?n=2` |
| 05 | A window, an app, or everything | `FeatureShots.swift` |
| 06 | Recordings | `FeatureShots.swift` |
| 07 | Text inside images | `shots.html?n=3` |
| 08 | Pinboards | `shots.html?n=4` |
| 09 | Privacy | `shots.html?n=5` |
| 10 | Right-click menu | `shots.html?n=6` |

**HTML frames** are plain HTML in `shots.html`, selected with `?n=`. `shoot.sh N`
renders one through headless Chrome at 2× from a 1440×900 window:

    ./shoot.sh 1          # writes out/1.png

**Capture frames** (02, 03, 05, 06) are rendered by a development build of the
app itself, so the overlay, toolbars, recording controls and recording cards in
them are CopyWell's own views:

    CopyWell.app/Contents/MacOS/CopyWell --render-feature-shots
    # writes ~/Library/Containers/com.copywell.app/Data/Documents/Screenshots/features/

Both share the same tokens — glow positions and sizes, header type, the
display frame, the callout capsule — so a change to one belongs in the other.
