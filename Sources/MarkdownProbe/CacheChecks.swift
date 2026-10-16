import AppKit
import MarkdownConversion

@MainActor
func checkMarkdownCache() async -> Bool {
    var success = true
    func check(_ name: String, _ passed: Bool) {
        print("\(passed ? "PASS" : "FAIL") \(name)")
        success = success && passed
    }
    func request(_ text: String) -> MarkdownCache.Request {
        MarkdownCache.Request(id: UUID(), rawText: text,
            representations: ["public.html": Data("<strong>\(text)</strong>".utf8)])
    }
    let changeCount = NSPasteboard.general.changeCount
    var started: [UUID] = []
    var finished: [UUID] = []
    let cache = MarkdownCache { request in
        started.append(request.id)
        try await Task.sleep(nanoseconds: 40_000_000)
        finished.append(request.id)
        return "**\(request.rawText)**"
    }
    let first = request("first")
    let second = request("second")
    cache.synchronize([first, second])
    do {
        try await Task.sleep(nanoseconds: 10_000_000)
        check("复制后无需粘贴即启动后台任务，且串行处理", started == [first.id] && finished.isEmpty)
        let cancelledWait = Task { @MainActor in try await cache.value(for: first.id) }
        cancelledWait.cancel()
        do {
            _ = try await cancelledWait.value
            check("取消等待不应粘贴", false)
        } catch is CancellationError { check("取消等待不返回结果", true) }
        let firstResult = try await cache.value(for: first.id)
        check("等待使用同一任务并保留原始文字", firstResult == "**first**" && first.rawText == "first" && started.filter { $0 == first.id }.count == 1)
        let secondResult = try await cache.value(for: second.id)
        check("连续复制按顺序完成", secondResult == "**second**" && finished == [first.id, second.id])
        cache.synchronize([first, second])
        let reused = try await cache.value(for: first.id)
        check("重复粘贴和来源更新复用缓存", reused == firstResult && started.count == 2)
        cache.synchronize([second])
        do { _ = try await cache.value(for: first.id); check("删除后缓存不可读", false) }
        catch { check("删除后缓存不可读", true) }
        cache.synchronize([])
        do { _ = try await cache.value(for: second.id); check("清空后缓存不可读", false) }
        catch { check("清空后缓存不可读", true) }

        var attempts = 0
        let failing = MarkdownCache { _ in attempts += 1; throw ProbeError.message("expected failure") }
        failing.synchronize([first])
        for _ in 0..<2 {
            do { _ = try await failing.value(for: first.id); check("缓存失败不能伪装成功", false) }
            catch { /* Expected; the same failure must be reused. */ }
        }
        check("失败被缓存，不重复转换或静默丢格式", attempts == 1)

        let evicted = request("evicted")
        cache.synchronize([evicted])
        try await Task.sleep(nanoseconds: 10_000_000)
        cache.synchronize([])
        try await Task.sleep(nanoseconds: 50_000_000)
        do { _ = try await cache.value(for: evicted.id); check("淘汰后的迟到结果不可恢复缓存", false) }
        catch { check("淘汰后的迟到结果不可恢复缓存", true) }

        let real = MarkdownCache()
        real.synchronize([first])
        let realResult = try await real.value(for: first.id)
        check("后台缓存实际调用共享转换内核", realResult == "**first**")
        real.synchronize([])
        check("后台准备不改写系统剪贴板", NSPasteboard.general.changeCount == changeCount)
    } catch { print("FAIL Markdown cache: \(error)"); success = false }
    return success
}
