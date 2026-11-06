#if os(tvOS)
import Foundation
import Observation
import TVPrototypeKit

@Observable @MainActor
final class TVUpdateModel {
    let preview: Bool
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    var checking = false
    var headline = "尚未检查更新"
    var detail = "检查最新 TV 版本和更新说明。"
    var release: TVUpdateFeed.Release?
    var checkedAt: Date?
    var automaticallyChecks: Bool {
        didSet { if !preview { UserDefaults.standard.set(automaticallyChecks, forKey: Self.preferenceKey) } }
    }
    private var lastAttempt: Date?
    private static let preferenceKey = "tv.automaticallyChecksUpdates"
    private var address: URL = TVUpdateFeed.address

    init(preview: Bool) {
        self.preview = preview
        automaticallyChecks = preview ? false : (UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--update-feed-test"), args.indices.contains(index + 1),
           let url = URL(string: args[index + 1]), url.scheme == "http",
           ["127.0.0.1", "localhost"].contains(url.host) { address = url }
        #endif
    }

    func checkIfNeeded() async {
        guard !preview, automaticallyChecks,
              lastAttempt.map({ Date().timeIntervalSince($0) >= 6 * 60 * 60 }) ?? true else { return }
        await check()
    }

    func check() async {
        guard !checking else { return }
        checking = true; lastAttempt = Date()
        defer { checking = false }
        do {
            let feed: TVUpdateFeed
            let source: String
            if preview {
                feed = .init(releases: [.init(version: "0.1.1", build: build + 1,
                    notes: "示例更新：改进设备连接提示，完善诊断报告。\n这是一条界面示例，没有查询真实发行版本。",
                    publishedAt: "2026-11-06T00:00:00Z")])
                source = "示例数据 · 未发起网络请求"
            } else {
                (feed, source) = try await TVUpdateFeed.fetch(address: address)
            }
            release = feed.newest(after: build)
            checkedAt = Date()
            headline = release.map { "发现新版本 \($0.version)" } ?? (feed.releases.isEmpty ? "暂未发现可用的 TV 安装包" : "当前已是最新版本")
            detail = address == TVUpdateFeed.address ? source : "本地测试更新服务 · 示例发布数据"
        } catch is CancellationError {
            lastAttempt = nil
            headline = "检查已取消"
        } catch {
            if Task.isCancelled { lastAttempt = nil }
            release = nil
            checkedAt = nil
            headline = "暂时无法检查更新"
            detail = error.localizedDescription
        }
    }
}
#endif
