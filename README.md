<div align="center">

# Echo 📋

**你复制过的,如回声般唤回。**

一个轻量的 macOS 菜单栏剪贴板历史管理器。

自动记录最近 50 次复制,`⌘\` 呼出面板,**输入编号即可秒粘第 N 条**。

[功能](#-核心能力) · [快速开始](#-快速开始) · [工作流](#-工作流) · [权限](#-零权限优先) · [技术实现](#-技术实现) · [🌟 设计文档](#-可视化设计文档)

</div>

---

## 为什么是 Echo

复制了一段重要的内容,转眼又被新的复制覆盖了?Echo 把你复制过的**全部留痕**,需要时一键唤回。

不同于系统剪贴板只能粘"最新一条",Echo 让你回溯**最近 50 条**,而且支持**文本、图片、文件**三种类型——截图、复制的文件路径、选中的文字,统统记录在案。

## ✨ 核心能力

| | 能力 | 说明 |
|---|---|---|
| 🎯 | **全自动记录** | 监听剪贴板本身(非按键),覆盖所有复制来源——右键、`⌘X` 剪切、拖拽、App 内按钮统统不漏 |
| 🔢 | **编号秒粘** | 面板里输 `35` 回车 → 直接粘第 35 条。还支持关键词搜索、方向键浏览 |
| 🖼️ | **三类内容** | 纯文本(自动净化格式)+ 图片(截图/复制图片)+ 文件(Finder 复制的文件路径) |
| ⌨️ | **全局热键** | `⌘\` 呼出 Spotlight 风格面板,任意 App 中可用 |
| 📤 | **自动粘贴** | 选中后自动粘到当前 App 光标处,无需手动按 `⌘V` |
| ♻️ | **重启清空** | 历史纯内存,App 重启即初始化,隐私干净 |
| 🔒 | **零权限优先** | 记录 + 热键无需任何权限;仅"自动粘贴"可选授权 |

## 🚀 快速开始

```bash
swift build -c release
.build/release/Echo
```

菜单栏出现 Echo 图标,开始自动记录。按 `⌘\` 呼出历史面板。

> 首次使用"自动粘贴"时,系统会弹辅助功能授权引导——授权后选中条目即自动粘;不授权也能用,只是需回目标 App 自己按 `⌘V`。

## ⌨️ 工作流

```
① 正常复制(⌘C / 右键 / 拖拽)   →  Echo 自动记录进历史
② 按 ⌘\                          →  弹出历史选择面板
③ 选一条(数字 / 搜索 / 方向键)  →  自动粘到当前光标
```

**三种选择方式:**

| 方式 | 操作 | 适合场景 |
|---|---|---|
| **数字直达** | 输入 `35` 回车 | 知道是第几条,最快 |
| **关键词搜索** | 输入文字过滤 | 内容多,按词找 |
| **方向键浏览** | ↑↓ 移动高亮,回车确认 | 随便翻翻 |

## 📊 内容类型处理

| 类型 | 读取 | 存储 | 粘贴 |
|---|---|---|---|
| 纯文本 | `.string` 类型 | 内存字符串 | 写 `.string`(净化格式) |
| 图片 | `.tiff`/`.png` 像素数据 | 原图 PNG 落盘 + 内存缩略图 | 读回原图 → 写 `NSImage` |
| 文件 | `NSURL` 路径(零拷贝) | URL 字符串(内存) | 写 `NSURL`,接收方 App 自行读取 |

**文件粘贴**:Finder 复制的文件只存路径(零拷贝)。微信会把 `.png/.jpg` 当图片消息发、`.pdf/.zip` 当文件消息发。⚠️ 源文件被删/移动后路径失效。

**图片粘贴**:纯文本编辑器(终端/VS Code)不接受图片会静默失败;富文本场景(飞书文档/Word/Notes/微信)完全正常。

## 🔒 零权限优先

Echo 的设计哲学是**能用公开 API 就不碰敏感权限**:

| 功能 | 权限 | 实现 |
|---|---|---|
| 记录历史 | **无** | 轮询 `NSPasteboard.changeCount`,公开 API |
| 呼出热键 `⌘\` | **无** | Carbon `RegisterEventHotKey`,公开 API |
| 自动粘贴 | 辅助功能(**可选**) | `CGEvent` 模拟 `⌘V`;**无权限时自动降级**为仅写剪贴板 |

关掉"自动粘贴"开关后,Echo 完全零权限运行——这是相对同类工具的体验优势。

密码管理器类敏感内容(带 `ConcealedType` 标记)自动跳过,绝不记录。

## 🏗️ 技术实现

- **监听剪贴板而非按键**:轮询 `NSPasteboard.general.changeCount`(0.5s),覆盖全部复制来源,零权限。Maccy / Flycut / Paste 等同类工具的标准方案。
- **全局热键**:Carbon `RegisterEventHotKey` 注册系统级快捷键,公开 API,无需权限,比 CGEventTap 稳定。
- **图片三态**:原图 PNG 落 `~/Library/Caches/Echo/images/`,内存只持 ~128px 缩略图,粘贴时按需读回原图,启动清空整个目录。
- **焦点恢复粘贴**:选中条目前记录前置 App,粘贴时显式 `activate` 目标 App 再 `CGEvent` 模拟 `⌘V`——解决菜单栏 App 抢焦点导致粘贴失效的经典问题。
- **去重**:连续相同内容只更新时间戳置顶。文本用内容指纹、图片用 SHA256、文件用路径排序。
- **隐藏 Dock**:`NSApp.setActivationPolicy(.accessory)`,仅菜单栏运行。

## 📁 项目结构

```
Sources/Echo/
├── main.swift              # 入口,NSApplication(.accessory 模式)
├── AppDelegate.swift       # 菜单栏 UI + 装配各组件
├── ClipEntry.swift         # 历史项统一模型(三类型枚举)+ ImageRef
├── ImageCache.swift        # 图片原图落盘/读取/删除/启动清空
├── ClipboardWatcher.swift  # 0.5s 轮询 changeCount,触发采集
├── ClipboardReader.swift   # 主线程读 NSPasteboard,分类(文件/图片/文本)
├── HistoryStore.swift      # 内存环形队列(≤50)+ 去重 + 淘汰删盘
├── GlobalHotkey.swift      # Carbon RegisterEventHotKey 注册 ⌘\
├── QuickPanel.swift        # Spotlight 风格选择面板(NSPanel + SwiftUI)
├── Paster.swift            # 写剪贴板 + 激活目标App + CGEvent ⌘V(降级)
├── AppSettings.swift       # 配置持久化(UserDefaults)
├── SettingsWindow.swift    # 设置页(SwiftUI)
└── PermissionsManager.swift # 辅助功能权限检测与引导
```

## 📌 系统要求

- macOS 13(Ventura)及以上
- (可选)辅助功能权限——仅"自动粘贴"功能需要

## 🌟 可视化设计文档

想看 Echo 的完整设计思路?配套的 [design-plan.html](design-plan.html) 用架构图、UI 高保真预览和交互流程图把每个细节讲透了——从「为什么监听剪贴板而非按键」到三类内容的处理矩阵,一目了然。

> 💡 GitHub 默认显示源码,点右上角 **Raw** 或下载后用浏览器打开效果最佳(深色主题 + 交互式标签页)。

## License

MIT License · Copyright © 2026 akira82-ai
