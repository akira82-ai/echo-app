import AppKit

// 菜单栏后台 App 入口。
// 不使用 SwiftUI / @main，直接用 AppKit 手动启动 NSApplication，
// 通过 setActivationPolicy(.accessory) 隐藏 Dock 图标（等价于 LSUIElement=true）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不在 Dock 显示，仅菜单栏运行
app.run()
