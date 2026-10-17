<div align="center">

If Echo helps you, please consider giving it a [⭐ Star](https://github.com/akira82-ai/echo-app).

# Echo 📋

**A minimal intelligent clipboard for macOS.**

Recall copied content, paste Markdown, calculate, or ask a quick question — from one menu-bar panel.

**Clipboard history · Markdown paste · Instant calculation · Quick questions**

[English](README.md) · [简体中文](README.zh-CN.md)

[Features](#features) · [Install](#install) · [Usage](#usage) · [Privacy](#privacy-and-permissions)

Featured in [Awesome Swift macOS Apps](https://github.com/jaywcjlove/awesome-swift-macos-apps).

</div>

## Demo

https://github.com/user-attachments/assets/cfd745c4-c36e-4929-8fda-0585ff2de70a

## Features

- **Clipboard history** — Capture copied text, images, and Finder files. Open with `⌘\` to search, select, and paste.
- **Markdown paste** — Convert captured rich text to Markdown locally, including headings, links, lists, code blocks, and simple tables.
- **Batch paste** — Select up to five text items and paste them together in selection order, as plain text or Markdown.
- **Instant calculation** — Start with `!` or `！` to calculate without leaving the panel.
- **Quick questions** — Start with `@` for streamed DeepSeek answers, with model-directed web search and page reading. Requires your own API key.
- **Copy sources** — See available app names or browser URLs, and reopen an observed page in Safari, Chrome, Edge, or Ego. Attribution is best-effort.
- **Native interface** — Light and dark appearances, Reduce Motion support, and Simplified Chinese, English, and Japanese interfaces.

## Install

Requires **macOS 13 Ventura or later**. Current prebuilt packages are for **Apple Silicon**; Intel Macs require a source build.

### Download a Release

Download `Echo.dmg` from the latest [Release](https://github.com/akira82-ai/echo-app/releases/latest), open it, and drag Echo to Applications. A ZIP is also available.

Current version: **2.11.0 (build 19)**.

Releases use `Echo Self-Sign`, rather than Apple Developer ID signing or notarization. If macOS blocks the first launch, attempt to open Echo, then go to **System Settings → Privacy & Security → Open Anyway** and confirm.

### Build from source

Install Xcode or Apple's Command Line Tools with **Swift 6.2 or later** (required by the current dependencies), then run:

```bash
git clone https://github.com/akira82-ai/echo-app.git
cd echo-app
./build-app.sh
open dist/Echo.app
```

The script builds and packages the app, using `Echo Self-Sign` when available or ad-hoc signing otherwise. Launch `dist/Echo.app` so bundled resources and permissions work as expected. The first build downloads dependencies.

## Usage

Copy normally, press `⌘\`, select an item, and press Return. Auto Paste requires Accessibility permission; without it, return to the target app and press `⌘V`.

| In the panel | Action |
| --- | --- |
| `1`–`5`, then Return | Paste that item on the current page |
| A keyword or number `6+` | Search history |
| Arrow keys | Browse history |
| `↵` / `⌥↵` | Paste original / Markdown |
| Hold `⌘`, then click or press `⌘↵` | Add or remove a text item from the batch |
| Release `⌘`, then `↵` / `⌥↵` | Paste the batch as plain text / Markdown |
| `⌥⌫` | Delete the current item |
| Right-click → Open Source Page, or `⌃↵` | Open the recorded browser page, when available |
| `Tab` | Toggle the clipboard shortcut guide |
| `Esc` | Close the panel or cancel a Markdown wait |

### Markdown paste

Press `⌥↵` for Markdown; ordinary Return preserves the original format. Plain text passes through unchanged. Conversion is prepared locally after capture without changing the clipboard or list preview.

Merged/nested tables and image attachments are not fully supported. Conversion failures leave the clipboard unchanged; use Return to paste the original instead.

### Instant calculation

Type `! (128+36)/4` to calculate. Supports full-width parentheses, arithmetic, `sqrt(81)`, `pow(2,3)`, and more; `%` means remainder.

Return pastes the result and closes the panel. With no text selected, `⌘C` copies the result and keeps the panel open. Remove the prefix to restore search. Results use floating-point arithmetic with up to 15 significant digits, not exact decimal accounting.

### Quick questions

In Settings → Model settings, save your **DeepSeek API key**. The endpoint (`https://api.deepseek.com/v1`) and model (`deepseek-chat`) are fixed; the key is stored in macOS Keychain.

Type `@ question` and press Return. With no text selected, `⌘C` copies the completed answer. Editing clears the answer and cancels the request; `Esc` closes and cancels. Remove `@` to return to search. Reopening restores the last question in memory, without its answer or an automatic resend.

The model can use [DeepSeek Search / Fetch](https://api-docs.deepseek.com/guides/search) with the same key, without a separate switch. It is instructed to cite sources; check important facts and links. Questions are independent: no previous conversation or clipboard history is automatically included.

## Privacy and permissions

- **Local clipboard data:** History and Markdown caches are not restored after restarting Echo. Image originals are cached under `~/Library/Caches/Echo/images/`; files are removed when their entries are deleted or evicted, and the image cache is cleared on startup. Settings and existing usage counters remain local.
- **Optional Accessibility access:** Basic recording and the global shortcut need no permission. Auto Paste and browser URL capture require Accessibility permission. Browser attribution may be missing or inaccurate.
- **DeepSeek requests:** Quick questions send your input, model-generated search queries, and page URLs to DeepSeek; web results are returned to the model. Content you manually paste into a question is sent too. The provider may retain requests and charge for chat and web usage.

If Auto Paste fails, enable Echo in **System Settings → Privacy & Security → Accessibility** and check **Enable Auto Paste** in Echo settings. You can still paste manually with `⌘V`.

## License

[MIT](LICENSE) · Copyright © 2026 akira82-ai. Dependency licenses and notices are included in the app resources.
