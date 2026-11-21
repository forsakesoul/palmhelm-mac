import Foundation

/// 运行环境：测试 scheme 显式标记宿主，统一隔离偏好、钥匙串与真实子进程。
/// 判定集中在这里（AppBoot 也用它）：测试宿主下一律不读写真实偏好与钥匙串。
enum RuntimeEnvironment {
    static let isTestHost: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["REINS_TEST_HOST"] == "1" { return true }
        // 测试包是在 didFinishLaunching 之后注入的，不能只看 XCTest 类是否已加载
        return NSClassFromString("XCTestCase") != nil || env.keys.contains { $0.hasPrefix("XCTest") || $0.hasPrefix("XCInject") }
    }()

    /// 发行构建（#108）：只有 scripts/package-mac.sh 的正式打包链在编译时打开 PALMHELM_DISTRIBUTION，且要求非 DEBUG、非测试宿主、正式 bundle id。
    /// 普通 Xcode Release / build-for-testing 不带标记，没有偏好或环境变量能把它打开。非发行构建不修改共享的 Claude 钩子。
    static let isDistribution: Bool = {
        #if PALMHELM_DISTRIBUTION && !DEBUG
        return !isTestHost && Bundle.main.bundleIdentifier == "com.forsakesoul.palmhelm.mac"
        #else
        return false
        #endif
    }()
}

/// App 的偏好存储：生产是 UserDefaults.standard；测试宿主下是独立 suite「PalmhelmMacTests」（每个进程第一次使用时清空），
/// 这样测试里 forget()、切视角、换主题等都不会改到真实 App 的偏好（bridge.* 端点、palmhelm.lens、已读标记、主题…）。
enum AppDefaults {
    static let testSuiteName = "PalmhelmMacTests"
    nonisolated(unsafe) static let standard: UserDefaults = { // UserDefaults 自身线程安全
        guard RuntimeEnvironment.isTestHost, let d = UserDefaults(suiteName: testSuiteName) else { return .standard }
        d.removePersistentDomain(forName: testSuiteName)
        return d
    }()
}
