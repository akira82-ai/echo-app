import AppKit

if CommandLine.arguments.contains("--prompt-self-test") {
    exit(runPromptChecks() ? 0 : 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--prompt-request-test"),
   CommandLine.arguments.count > index + 1, let port = Int(CommandLine.arguments[index + 1]) {
    Task { @MainActor in
        exit(await runPromptRequestChecks(port: port) ? 0 : 1)
    }
    RunLoop.main.run()
}

if let index = CommandLine.arguments.firstIndex(of: "--chat-self-test"),
   CommandLine.arguments.count > index + 1, let port = Int(CommandLine.arguments[index + 1]) {
    Task { @MainActor in
        let passed = await runChatChecks(port: port)
        if !passed { print("FAIL chat checks") }
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
}

// 菜单栏后台 App 入口。
// 不使用 SwiftUI / @main，直接用 AppKit 手动启动 NSApplication，
// 通过 setActivationPolicy(.accessory) 隐藏 Dock 图标（等价于 LSUIElement=true）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不在 Dock 显示，仅菜单栏运行
app.run()
