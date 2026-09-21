<div align="center">

If Echo helps you, please consider giving it a [⭐ Star](https://github.com/akira82-ai/echo-app).

# Echo 📋

**A minimal intelligent clipboard for macOS. | Recall what you copied, like an echo.**

Echo lives in your Mac menu bar, automatically saves copied text, images, and files, then lets you find and paste them back with one shortcut.

**Smart capture · Fast recall · Intelligent search · Achievement system**

[English](README.md) · [简体中文](README.zh-CN.md)

[Features](#-features) · [Quick Start](#-quick-start)

</div>

---

## 🎬 Demo

https://github.com/user-attachments/assets/cfd745c4-c36e-4929-8fda-0585ff2de70a

## ✨ Features

- 🎯 **Automatic capture** — Watches the clipboard itself rather than keystrokes, so copies from context menus, cuts, drag-and-drop, and in-app buttons are all captured.
- 🔢 **One input, three intents** — Type `1`–`5` to select an item on the current page; type `6+` or a keyword to search; leave it empty to browse with the arrow keys.
- ✦ **Useful empty state** — `⌘\` still opens the panel when history is empty and shows what to do next.
- 🖼️ **Three content types** — Text (format preserved, with plain-text paste), images, and files copied from Finder.
- ⌨️ **Global shortcut** — Open the Spotlight-style panel with `⌘\` from any app.
- ✨ **Subtle entrance motion** — The panel and first page appear naturally while respecting macOS Reduce Motion.
- 🎯 **Continuous selection feedback** — The highlight follows keyboard movement smoothly and keeps batch selections clear.
- 🧩 **Batch text paste** — Hold `⌘`, click or press `⌘↵` to add up to five text items, then release `⌘` and press `↵` to paste them in order as one block.
- 🧹 **Quick cleanup** — Press `⌥⌫` to remove the current item without taking over Backspace in search.
- ⌘ **Shortcut reference** — Press `Tab` to view a compact three-column reference for general, normal, and batch-mode shortcuts; press `Esc` to return.
- 📤 **Auto Paste** — Selecting an item pastes it into the focused app without a separate `⌘V`.
- 🏅 **Achievements** — Tracks shortcuts, search, cleanup, and long-term habits across twelve medals.
- 🌐 **System language support** — The interface follows macOS and is available in Simplified Chinese, English, and Japanese.
- 🔒 **Permissions first** — Capturing and the shortcut require no permissions; Auto Paste is optional and can be disabled at any time.
- ♻️ **On-device by default** — History stays in memory and achievement statistics store only local counters and dates.

## 🚀 Quick Start

### Option 1: Build from source

```bash
# Build, package, and sign dist/Echo.app and dist/Echo.dmg
./build-app.sh
open dist/Echo.app
```

`build-app.sh` automatically uses the local `Echo Self-Sign` certificate. Run it again after changes; manual re-signing is not needed. Always launch `dist/Echo.app`, not `.build/.../Echo` directly.

### Option 2: Download a Release

Visit [Releases](https://github.com/akira82-ai/echo-app/releases) and download `Echo.dmg` from the latest `2.5.0` release. Open the DMG and drag Echo to Applications.

Current releases are development-verified builds signed with `Echo Self-Sign`, not Apple Developer ID-signed or notarized distribution builds. The first launch may be blocked by macOS:

1. In Finder, Control-click Echo, choose **Open**, then confirm **Open** once more.
2. If it is still blocked, open **System Settings → Privacy & Security**, click **Open Anyway** beside the security notice, then start Echo again.

The first use of Auto Paste opens macOS Accessibility permission guidance. Once granted, selecting an item pastes it automatically. Without permission, Echo still copies the item back to the clipboard for manual `⌘V`.

```
1. Copy normally (⌘C / context menu / drag)       → Echo saves it to history
2. Press ⌘\                                      → Open the history panel
3. Select an item (1–5 / 6+ search / arrow keys) → Paste into the focused app
   Use ⌥↵ to paste plain text; formatting is preserved by default.
4. Hold ⌘, select up to five text items, release ⌘, then press ↵ to paste them together in order.
5. Press ⌥⌫ to remove the current item and keep organizing.
6. Press Tab for the shortcut reference; press Esc to return to history.
```

**System requirements:** macOS 13 Ventura or later.

### Auto Paste troubleshooting

If selecting a history item does not paste automatically, first confirm that `dist/Echo.app` is running. Then check that Echo is granted access under **System Settings → Privacy & Security → Accessibility** and that **Enable Auto Paste** is enabled in Settings. Even without permission, Echo writes the item back to the clipboard so you can paste manually with `⌘V`.

---

## License

MIT License · Copyright © 2026 akira82-ai
