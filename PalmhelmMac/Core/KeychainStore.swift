import Foundation
import Security
import PalmhelmKit

// 机密进钥匙串（设备令牌、飞书 App Secret）；地址等非机密进 UserDefaults（AppDefaults.standard：测试宿主下是独立 suite）。
enum KeychainStore {
    /// 正式版的 bundle id。正式版的钥匙串服务名保持原名，正式用户零迁移。
    static let formalBundleID = "com.forsakesoul.palmhelm.mac"

    /// 服务名由 bundle id 派生（#100）：各构建互不共享钥匙串条目。缺 id 返回 nil，调用方 fail closed，绝不回退到正式名。
    static func serviceName(bundleID: String?) -> String? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        return id
    }

    /// 本进程的钥匙串服务名；nil 时读写全部失败。
    static var service: String? { serviceName(bundleID: Bundle.main.bundleIdentifier) }

    /// 测试宿主下机密只存内存（绝不读写真实钥匙串：测试里的 forget() 曾删掉真实 App 的设备令牌，导致重复自配对）。
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        func set(_ v: String?, _ k: String) { lock.withLock { items[k] = v } }
        func get(_ k: String) -> String? { lock.withLock { items[k] } }
    }
    private static let memory = Memory()
    /// 当前后端是不是内存实现（测试用来断言隔离生效）。
    static var usesMemoryBackend: Bool { RuntimeEnvironment.isTestHost }

    @discardableResult
    static func save(_ value: String, account: String) -> Bool {
        if RuntimeEnvironment.isTestHost { memory.set(value, account); return true }
        guard let service else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(account: String) -> String? {
        if RuntimeEnvironment.isTestHost { return memory.get(account) }
        guard let service else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 不在主线程读钥匙串：securityd 偶发长时间不响应（刚退出的旧实例还在收尾时尤其容易），同步读会卡死整个 App 启动。
    static func loadAsync(account: String) async -> String? {
        await Task.detached(priority: .userInitiated) { load(account: account) }.value
    }

    static func delete(account: String) {
        if RuntimeEnvironment.isTestHost { memory.set(nil, account); return }
        guard let service else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    // ---- 本机与内置 Bridge 的设备令牌 ----
    static let tokenAccount = "device-token"

    static func saveEndpoint(_ ep: BridgeEndpoint) {
        let d = AppDefaults.standard
        d.set(ep.host, forKey: "bridge.host")
        d.set(ep.port, forKey: "bridge.port")
        d.set(ep.transport.rawValue, forKey: "bridge.transport")
        d.set(ep.spkiSha256, forKey: "bridge.spki")
    }

    static func loadEndpoint() -> BridgeEndpoint? {
        let d = AppDefaults.standard
        guard let host = d.string(forKey: "bridge.host"), !host.isEmpty else { return nil }
        let transport = Transport(rawValue: d.string(forKey: "bridge.transport") ?? "") ?? .http
        let spki = d.string(forKey: "bridge.spki")
        if transport == .https && spki == nil { return nil }
        let port = d.integer(forKey: "bridge.port")
        return BridgeEndpoint(host: host, port: port == 0 ? BridgeAPI.defaultPort : port, transport: transport, spkiSha256: spki)
    }

    static func clearEndpoint() {
        let d = AppDefaults.standard
        for k in ["bridge.host", "bridge.port", "bridge.transport", "bridge.spki"] { d.removeObject(forKey: k) }
        delete(account: tokenAccount)
    }
}
