<div align="center">

Like simple, handy Mac tools? Give Echo a [⭐ Star](https://github.com/akira82-ai/echo-app) to support its continued development.

# Echo 📋

**A minimal intelligent clipboard for macOS.**

Recall copied content, paste Markdown, calculate, or ask a quick question — from one menu-bar panel.

**Clipboard history · Markdown paste · Instant calculation · Quick questions**

[Download Echo. Make copy and paste feel easier. →](https://github.com/akira82-ai/echo-app/releases/latest)

[English](README.md) · [简体中文](README.zh-CN.md)

[Features](#features) · [FAQ](#faq) · [Usage](#usage) · [Install](#install) · [Privacy](#privacy-and-permissions)

Featured in [Awesome Swift macOS Apps](https://github.com/jaywcjlove/awesome-swift-macos-apps).

</div>

## Demo

https://github.com/user-attachments/assets/2fa21d5d-e4a0-42c7-bee8-ceb0c1b1ccef

## Features

- **Copied it? Find it again.** — Text, images, and Finder files are captured automatically. Press `⌘\`, search, pick an item, and keep going.
- **From clipping to notes, with less cleanup.** — Paste copied rich text as Markdown, keeping common structures such as headings, links, and lists. Conversion happens entirely on your Mac.
- **Several clips. One paste.** — Combine up to five text items in the order you choose. Gather excerpts and piece together notes with fewer trips between apps.
- **Do the math. Keep your focus.** — Start with `!`, then press Return to use the result. From simple arithmetic to common functions, no separate calculator needed.
- **A quick question, right here.** — Type `@` to ask DeepSeek in the same panel. Watch the answer arrive as it is generated, with model-directed web search and page reading when needed. Bring your own API key.
- **Make the assistant yours.** — Edit the system prompt in Model Settings, restore Echo's default, and shape the tone and rules of every new quick question.
- **Room for real questions.** — The input stays compact for quick searches, then expands in place for longer or multi-line prompts without moving the panel frame. Press `⇧↵` for a new line and `Esc` to collapse it.
- **Find the clip—and its source.** — See the source app or webpage when available. Reopen a captured URL in one step to keep reading or check the context.
- **At home on your Mac.** — Follows your system's light or dark appearance, respects Reduce Motion, and speaks Chinese, English, and Japanese. Open it when needed; dismiss it when done.

## FAQ

**What is Echo, in one sentence?**
A minimal intelligent clipboard in your Mac's menu bar: recall copied content, paste Markdown, calculate, and ask quick questions — one panel does it all. Free and open source (MIT). No subscription, no in-app purchases, no account.

**I already use Maccy / Paste / Raycast. Is Echo still worth a try?**
Depends on which step you're missing:
- You like Maccy's simplicity but want Markdown paste, calculation, and quick questions → give Echo a try;
- You need a persistent history database like Paste's → that's what it does best. Echo takes a different path: the clipboard is a scratchpad — cleared on restart, nothing left behind;
- Heavy Raycast user → stick with Raycast. Echo is for people who just want to paste some text, run a quick calculation, or ask a quick question — without installing a whole launcher for it.

**Will my clipboard data be uploaded?**
No. History and caches stay on your Mac and are cleared on restart (details under Privacy and permissions). A quick question sends the question and your saved system prompt to DeepSeek; clipboard history is never uploaded automatically.

**Does a quick question send my clipboard history to DeepSeek?**
No. Only the question you type — plus anything you manually paste into it — is sent. Clipboard history is never attached automatically, and questions are independent, with no memory of each other. When verification is needed, the model's search queries and page URLs are sent to DeepSeek's search service.

**Why do I need my own API key for quick questions?**
Echo doesn't proxy or touch your quota: the key lives in the macOS Keychain, and requests go straight from your machine to DeepSeek. You stay in full control of usage and cost.

**What are the limits of Markdown paste?**
Common structures such as headings, links, and lists are preserved; merged/nested tables and image attachments are not fully supported yet. If a conversion fails, the clipboard stays untouched, and Return still pastes the original.

**Why does macOS say Echo "can't be opened"?**
Echo is self-signed and not notarized by Apple. Try opening it, then go to System Settings → Privacy & Security and click Open Anyway (see Install). If you'd rather not, build it from source yourself — that's what open source is for.

**Why does Auto Paste need Accessibility permission?**
Writing back into the target app requires it. Without granting it, everything still works: press Return to copy, then `⌘V` in the target app (see Usage). Basic clipboard capture and the `⌘\` shortcut need no permission at all.

## Usage

Copy normally, press `⌘\`, select an item, and press Return. Auto Paste requires Accessibility permission; without it, return to the target app and press `⌘V`.

Edit the input with familiar Mac shortcuts: `⌘A` selects all, `⌘V` pastes plain text, and `⌘X` / `⌘C` cut or copy selected text. `⌘Z` / `⇧⌘Z` undo or redo when available. These work in clipboard search, calculation, and quick questions; `Ctrl+A` keeps its macOS text-editing behavior.

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

The system prompt is editable in Settings → Model Settings. Save to apply it to the next question; ongoing requests keep their original prompt. Custom prompts are stored locally, sent to the model with each question, and survive upgrades. Restore the default and save to use the bundled default, which can evolve with app updates. Date, timezone and actual tool availability are added at request time. Default answers are concise, conclusion-first and suited to the single-turn panel.

In Settings → Model settings, save your **DeepSeek API key**. The endpoint (`https://api.deepseek.com/v1`) and model (`deepseek-chat`) are fixed; the key is stored in macOS Keychain.

Type `@ question` and press Return. With no text selected, `⌘C` copies the completed answer. Editing clears the answer and cancels the request; `Esc` closes and cancels. Remove `@` to return to search. Reopening restores the last question in memory, without its answer or an automatic resend.

The model can use [DeepSeek Search / Fetch](https://api-docs.deepseek.com/guides/search) with the same key, without a separate switch. It is instructed to cite sources; check important facts and links. Questions are independent: no previous conversation or clipboard history is automatically included.

## Install

Requires **macOS 13 Ventura or later**. Current prebuilt packages are for **Apple Silicon**; Intel Macs require a source build.

### Download a Release

Download `Echo.dmg` from the latest [Release](https://github.com/akira82-ai/echo-app/releases/latest), open it, and drag Echo to Applications. A ZIP is also available.

Current version: **2.13.0 (build 23)**.

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

## Privacy and permissions

- **Local clipboard data:** History and Markdown caches are not restored after restarting Echo. Image originals are cached under `~/Library/Caches/Echo/images/`; files are removed when their entries are deleted or evicted, and the image cache is cleared on startup. Settings and existing usage counters remain local.
- **Optional Accessibility access:** Basic recording and the global shortcut need no permission. Auto Paste and browser URL capture require Accessibility permission. Browser attribution may be missing or inaccurate.
- **DeepSeek requests:** Quick questions send your input, saved system prompt, model-generated search queries, and page URLs to DeepSeek; web results are returned to the model. Content you manually paste into a question is sent too. The provider may retain requests and charge for chat and web usage.

If Auto Paste fails, enable Echo in **System Settings → Privacy & Security → Accessibility** and check **Enable Auto Paste** in Echo settings. You can still paste manually with `⌘V`.

## License

[MIT](LICENSE) · Copyright © 2026 akira82-ai. Dependency licenses and notices are included in the app resources.
