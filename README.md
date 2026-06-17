# Lark Assistant 📋

一个轻量的 macOS 菜单栏工具：**连续按三次 `⌘+C`，自动把当前选中的文本存到本地文件**，每天一个 Markdown 文件，按时间顺序追加记录。

## 功能

- 🎯 **三连 `⌘+C` 触发**：500ms 时间窗口内连按三次才触发，避免误触
- 📁 **每天一个文件**：自动写入 `~/Downloads/clippings_YYYY-MM-DD.md`
- 🕐 **带时间戳**：每条记录标注精确复制时间
- 🚫 **自动去重**：连续两次相同内容只记录一次
- 🍃 **菜单栏常驻**：仅顶部图标，不在 Dock 显示
- 🔒 **权限引导**：首次启动自动引导授予辅助功能权限

## 使用方式

### 1. 编译

```bash
swift build -c release
```

产物位于 `.build/release/LarkAssistant`。

### 2. 运行

```bash
.build/release/LarkAssistant
```

> ⚠️ **首次运行会弹出系统授权弹窗**：请点击「打开系统设置」，在「隐私与安全性 → 辅助功能」中开启本程序（或终端）的权限。授权后程序会**自动开始监听**，无需重启。

### 3. 触发收集

1. 在任意 App 中选中一段文本
2. **快速连按三次 `⌘+C`**（500ms 内）
3. 菜单栏图标会短暂变为 ✅，表示已保存
4. 打开 `~/Downloads/clippings_2026-06-17.md` 查看记录

### 4. 菜单栏功能

点击菜单栏的 📋 图标：

| 菜单项 | 功能 |
|---|---|
| 状态行 | 显示当前监听状态 / 今日收集条数 |
| 暂停监听 / 继续监听 | 临时关闭或恢复触发 |
| 打开今日文件 | 用默认编辑器打开当日 Markdown |
| 在 Finder 中显示 | 定位到文件位置 |
| 打开辅助功能设置… | 快速跳转系统设置 |
| 退出 | 关闭程序 |

## 文件格式

`~/Downloads/clippings_2026-06-17.md` 内容示例：

```markdown
---
🕐 2026-06-17 14:32:05

这是第一段被收集的文本内容。

---
🕐 2026-06-17 15:18:42

这是第二段被收集的文本内容。

```

## 项目结构

```
Sources/LarkAssistant/
├── main.swift              # 入口，NSApplication 启动（.accessory 模式）
├── AppDelegate.swift       # 菜单栏 UI + 生命周期
├── HotkeyMonitor.swift     # CGEventTap 全局监听，三连 ⌘+C 检测
├── ClipboardManager.swift  # 读剪贴板 + 去重
├── StorageManager.swift    # Markdown 文件追加写入
└── PermissionsManager.swift # 辅助功能权限检测与引导
```

## 技术要点

- **全局按键监听**：`CGEvent.tapCreate` 创建系统级事件 tap，需要辅助功能权限
- **三连检测**：维护最近按键时间戳数组，500ms 窗口内累计 3 次即触发
- **读剪贴板而非 Accessibility**：第三次 `⌘+C` 本身就是复制操作，内容已入 `NSPasteboard`，直接读取最稳定可靠
- **延迟读取**：触发后延迟 80ms 读剪贴板，确保系统已写入
- **隐藏 Dock**：运行时调用 `NSApp.setActivationPolicy(.accessory)`（等价于 `Info.plist` 的 `LSUIElement=true`）

## 系统要求

- macOS 13 (Ventura) 及以上
- 需授予「辅助功能」权限

## 开发提示

- 开发态用 `swift run` 时，被系统识别的是 `swift` / Terminal 进程，**需要给它们分别授权**
- 修改权限后若监听未恢复，可从菜单「打开辅助功能设置」或退出重启
- 若想调整时间窗口或延迟，见 `HotkeyMonitor.swift` 顶部的 `windowMilliseconds` 和 `clipboardReadDelayMs`

## License

MIT License · Copyright © 2026 akira82-ai
