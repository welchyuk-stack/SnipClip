# SnipClip App Preview capture

Smooth, repeatable recordings for the App Store preview.

- `rec`: records the screen at 60fps with Claude's windows left out.
- `drive`: plays back the eased mouse and keyboard steps in `clips/*.json`.

## One-time setup

1. Allow your terminal app (e.g. Terminal) in **System Settings › Privacy & Security › Accessibility**. That's what lets `drive` move the mouse. Also allow it under **Screen & System Audio Recording** for `rec`.
2. Build the tools:

   ```
   ./build.sh
   ```

3. Set macOS to Dark appearance and turn on Do Not Disturb.
4. Serve the sample page: `cd sample && python3 -m http.server 8765`, then open http://localhost:8765 in Safari.
5. Run the SnipClip debug test build so its capture overlay also hides Claude:

   ```
   SNIPCLIP_UITEST=1 SNIPCLIP_HIDE_BUNDLE=com.anthropic.claudefordesktop \
     /tmp/snipclip-uitest/Build/Products/Debug/SnipClip.app/Contents/MacOS/SnipClip &
   ```

   Quit the App Store copy first so the shortcuts don't clash.

## Recording a take

```
./take.sh 01_snip 15
```

Hands off the mouse until it finishes. It prints the unique-frame count when it's done. Clips land in `../raw/`.

| Clip | Set up first | Suggested seconds |
|---|---|---|
| 01_snip | Safari showing the Lumen page | 15 |
| 02_markup | The editor from 01 still open | 22 |
| 03_text | Close the editor (⌘W) | 12 |
| 04_pin | Lumen page visible | 18 |
| 05_scroll | Close any pin. Open `sample/Lumen Release Notes.rtf` in TextEdit, zoom the window (double-click the title bar), ⌘↑ to the top | 20 |

## Adjusting

Coordinates are screen points with a top-left origin, measured on this Mac's 1470×956 display. If something misses, it's usually one of these:

- **SnipClip's menu bar icon** (`[1114,15]`). Its position shifts when other menu bar icons change.
- **The Scrolling Capture panel's Stop button** (`[456,122]` in `05_scroll`). The panel appears above or below your selection.
- **Window positions** (Safari, the editor, TextEdit).

To find a point, hover over it and run (e.g. from a second terminal tab):

```
sleep 3; ./bin/drive --where
```

Or eyeball it: point coordinates are screenshot pixels ÷ 2.

The step format is documented at the top of `drive.swift`. Each action is followed by a 0.35s pause.
