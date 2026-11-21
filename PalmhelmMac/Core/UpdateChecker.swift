import Foundation
import PalmhelmKit
import Observation

// #115 方案 A：只感知新版并打开下载页，不下载、不替换。检查只访问 GitHub 公开 Releases 接口，不带任何用户信息。
// 纯逻辑（tag 解析、比较、跳过、节流）都在这里，数据源可注入，测试不连网。

/// 公开发行版：tag 形如 `v1.0-<构建号>`，构建号是唯一的先后依据。
struct UpdateRelease: Equatable {
    let version: String // "1.0"
    let build: Int
    let releaseURL: URL

    static let repoPrefix = "https://github.com/forsakesoul/palmhelm/"
    /// “更新内容”页：App 内选定的语言为中文时打开中文页，其余打开英文页（点击时求值，跟随语言切换）。
    static var changelogURL: URL { URL(string: repoPrefix + "blob/main/" + (KitL10n.isChinese ? "CHANGELOG.zh-CN.md" : "CHANGELOG.md"))! }
    var title: String { "\(version) (\(build))" }

    /// 草稿 / 预发布 / tag 不符 / 链接不属于本仓库 → nil（一律当作没有新版，不报错）。
    init?(tag: String, htmlURL: String?, draft: Bool, prerelease: Bool) {
        guard !draft, !prerelease, let m = tag.wholeMatch(of: /v(\d+(?:\.\d+)*)-(\d{1,9})/), let build = Int(m.2) else { return nil }
        version = String(m.1)
        self.build = build
        // 只信任本仓库的页面；接口给出别处的链接时退回按 tag 拼的 Release 页。
        if let s = htmlURL, s.hasPrefix(Self.repoPrefix), let u = URL(string: s) { releaseURL = u }
        else if let u = URL(string: Self.repoPrefix + "releases/tag/" + tag) { releaseURL = u }
        else { return nil }
    }
}

protocol UpdateSource: Sendable {
    /// 最新公开发行版；没有可识别的发行版返回 nil，网络 / 状态码 / 解析问题抛错。
    func latestRelease() async throws -> UpdateRelease?
}

struct GitHubUpdateSource: UpdateSource {
    let userAgent: String
    private struct Payload: Decodable { let tag_name: String; let html_url: String?; let draft: Bool?; let prerelease: Bool? }

    func latestRelease() async throws -> UpdateRelease? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/forsakesoul/palmhelm/releases/latest")!, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral // 不带 Cookie、不落缓存
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        return UpdateRelease(tag: p.tag_name, htmlURL: p.html_url, draft: p.draft ?? false, prerelease: p.prerelease ?? false)
    }
}

@MainActor @Observable
final class UpdateChecker {
    enum Status: Equatable { case idle, checking, upToDate, available(UpdateRelease), failed }

    static let autoKey = "palmhelm.update.auto"
    static let skippedKey = "palmhelm.update.skippedBuild"
    static let lastCheckKey = "palmhelm.update.lastCheck"
    static let interval: TimeInterval = 24 * 3600

    private(set) var status = Status.idle
    private(set) var dismissedBuild = 0 // 本次运行里关掉过横幅的构建号；下次启动会再提示，除非“跳过”
    private(set) var skippedBuild: Int
    var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: Self.autoKey) } }

    /// 发行构建才联网（Debug / 测试宿主默认 false）。
    let networkEnabled: Bool
    private let source: any UpdateSource
    private let currentBuild: Int?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(source: any UpdateSource, currentBuild: Int?, networkEnabled: Bool, defaults: UserDefaults = AppDefaults.standard, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.currentBuild = currentBuild
        self.networkEnabled = networkEnabled && currentBuild != nil
        self.defaults = defaults
        self.now = now
        autoCheck = defaults.object(forKey: Self.autoKey) as? Bool ?? true
        skippedBuild = defaults.integer(forKey: Self.skippedKey)
    }

    /// 生产装配：当前构建号取自 CFBundleVersion；只有发行构建联网。
    static func production() -> UpdateChecker {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return UpdateChecker(source: GitHubUpdateSource(userAgent: "Palmhelm-Mac/\(version) (\(build))"),
                             currentBuild: Int(build), networkEnabled: RuntimeEnvironment.isDistribution)
    }

    /// 有新版、没被跳过、本次运行里没被关掉 → 才显示提示。
    var banner: UpdateRelease? {
        guard case .available(let r) = status, r.build > skippedBuild, r.build > dismissedBuild else { return nil }
        return r
    }

    var lastCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    func dismiss() { if case .available(let r) = status { dismissedBuild = r.build } }
    func skip() { if case .available(let r) = status { skippedBuild = r.build; defaults.set(r.build, forKey: Self.skippedKey) } }

    /// 用户点“立即检查”：不看开关与节流，结果写进 status（失败也显示）。
    func checkNow() async { await check(silent: false) }

    /// 自动检查：开关关闭、非发行构建、24 小时内成功检查过 → 什么都不做。失败安静忽略。
    func checkIfDue() async {
        guard autoCheck, networkEnabled else { return }
        if let last = lastCheck, now().timeIntervalSince(last) < Self.interval { return }
        await check(silent: true)
    }

    /// 启动后延迟片刻检查一次，之后每小时复核一次是否到期（失败不记成功时间，下个整点重试）。
    func runLoop(startDelay: Duration = .seconds(20), tick: Duration = .seconds(3600)) async {
        guard networkEnabled else { return }
        try? await Task.sleep(for: startDelay)
        while !Task.isCancelled {
            await checkIfDue()
            do { try await Task.sleep(for: tick) } catch { return }
        }
    }

    private func check(silent: Bool) async {
        guard networkEnabled, let currentBuild, status != .checking else {
            if !silent, !networkEnabled { status = .failed }
            return
        }
        let before = status
        status = .checking
        do {
            let latest = try await source.latestRelease()
            defaults.set(now(), forKey: Self.lastCheckKey)
            if let latest, latest.build > currentBuild { status = .available(latest) } else { status = .upToDate }
        } catch {
            status = silent ? before : .failed
        }
    }
}
