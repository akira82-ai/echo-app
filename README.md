# Echo 📋

> 你复制过的,如回声般唤回。

一个轻量的 macOS 菜单栏剪贴板历史管理器:**自动记录最近 50 次复制**(文本 / 图片 / 文件),按 `⌘\` 呼出面板,**输入编号即可秒粘第 N 条**。

## 功能

- 🎯 **自动记录**:监听剪贴板本身(非按键),覆盖所有复制来源——右键、`⌘X` 剪切、拖拽、App 内按钮统统不漏
- 🔢 **三种选择方式**:输入数字直达第 N 条 / 关键词搜索 / 方向键导航
- 🖼️ **三类内容**:纯文本(自动丢弃 RTF/HTML 格式)+ 图片(截图/复制图片)+ 文件(Finder 复制的本地文件)
- ⌨️ **全局热键**:`⌘\` 呼出选择面板(可配置,Carbon 公开 API,零权限)
- 📤 **自动粘贴**:选中后自动模拟 `⌘V` 粘到当前 App(可关闭,关闭后零权限运行)
- ♻️ **重启清空**:历史纯内存,App 重启即初始化;图片原图落临时磁盘缓存,启动自动清空
- 🔒 **隐私干净**:本地运行,数据不出本机;密码管理器类敏感内容自动跳过

## 使用方式

### 1. 编译

```bash
swift build -c release
```

产物位于 `.build/release/Echo`。

### 2. 运行

```bash
.build/release/Echo
```

菜单栏会出现一个图标。无需任何权限即可开始记录历史(自动粘贴除外)。

### 3. 日常使用

1. 在任意 App 中正常复制(`⌘C` / 右键 / 拖拽都行)——内容自动入历史
2. 按 **`⌘\`**(或在菜单栏点"显示历史")呼出面板
3. 选择要粘贴的历史项:
   - **数字直达**:输入 `35` 回车 → 直接粘第 35 条
   - **搜索**:输入关键词过滤(文本/文件),方向键选中后回车
   - **浏览**:↑↓ 移动高亮,回车粘贴
4. 选中后自动粘贴到当前 App 光标处(若已授予辅助功能权限)

### 4. 菜单栏功能

| 菜单项 | 功能 |
|---|---|
| 显示历史 `⌘\` | 呼出选择面板 |
| 清空历史 | 立即清空所有历史(并删除图片缓存) |
| 已收集 N 条 | 当前历史条数 |
| 设置… | 历史上限 / 热键 / 自动粘贴开关 / 清空 |
| 打开辅助功能设置… | 授予自动粘贴所需权限(可选) |

## 权限说明

Echo 的设计哲学是**零权限优先**:

| 功能 | 权限 | 说明 |
|---|---|---|
| 记录历史 | 无 | 轮询 `NSPasteboard.changeCount`,公开 API |
| 呼出热键 `⌘\` | 无 | Carbon `RegisterEventHotKey`,公开 API |
| 自动粘贴 | 辅助功能(可选) | `CGEvent` 模拟 `⌘V` 需要;**无权限时自动降级**为仅写剪贴板 |

> 首次启用自动粘贴时,系统会弹出授权引导。授权后选中历史项即可一步粘贴;不授权也能用,只是需要回目标 App 自己按 `⌘V`。

## 内容类型处理

| 类型 | 读取 | 存储 | 粘贴 |
|---|---|---|---|
| 纯文本 | `.string` 类型 | 内存字符串 | 写 `.string` |
| 图片 | `.tiff`/`.png` 像素数据 | 原图 PNG 落盘 + 内存缩略图 | 读回原图 → 写 `NSImage` |
| 文件 | `NSURL` 路径(零拷贝) | URL 字符串(内存) | 写 `NSURL`,接收方 App 自行读取 |

**文件粘贴说明**:Finder 复制的文件只存路径指针(零拷贝)。粘贴到不同 App 的效果由接收方决定——微信会把 `.png/.jpg` 当图片消息发、把 `.pdf/.zip` 当文件消息发。⚠️ 源文件被删/移动后路径失效,粘贴会失败(剪贴板历史不做文件备份)。

**图片粘贴说明**:纯文本编辑器(终端、Sublime、VS Code 普通模式)不接受图片,会静默失败;富文本场景(飞书文档 / Word / Notes / 微信)完全正常。

## 项目结构

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
├── Paster.swift            # 写剪贴板 + CGEvent 模拟 ⌘V(降级)
├── AppSettings.swift       # 配置持久化(UserDefaults)
├── SettingsWindow.swift    # 设置页(SwiftUI)
└── PermissionsManager.swift # 辅助功能权限检测与引导
```

## 技术要点

- **监听剪贴板而非按键**:轮询 `NSPasteboard.general.changeCount`(0.5s),覆盖全部复制来源,零权限。这是 Maccy / Flycut / Paste 等同类工具的标准方案。
- **全局热键**:Carbon `RegisterEventHotKey` 注册系统级快捷键,公开 API,无需权限。
- **图片三态**:原图 PNG 落 `~/Library/Caches/Echo/images/`,内存只持 ~128px 缩略图,粘贴时按需读回原图,启动清空整个目录。
- **去重**:连续相同内容只更新时间戳置顶,不重复占名额。文本用内容指纹、图片用 SHA256、文件用路径排序。
- **降级粘贴**:`AXIsProcessTrusted()` 为假时静默跳过 `⌘V` 模拟,只写剪贴板,绝不弹窗打扰。
- **隐藏 Dock**:`NSApp.setActivationPolicy(.accessory)`,仅菜单栏运行。

## 系统要求

- macOS 13(Ventura)及以上
- (可选)辅助功能权限——仅"自动粘贴"功能需要

## License

MIT License · Copyright © 2026 akira82-ai
