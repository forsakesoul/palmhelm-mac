import Foundation
import PalmhelmKit

/// 本机管理口里自配对用到的几个操作（测试可注入假实现，不碰真实 Bridge）。
protocol HookAdmin: Sendable {
    func issuePairCode() async throws -> HookClient.PairCode
    func setPermission(deviceId: String, _ permission: DevicePermission) async throws
    func devices(all: Bool) async throws -> [HookClient.Device]
    func remove(deviceId: String) async throws
}

// 本机 owner 管理入口：Hook 密钥 + 回环（Bridge 钩子口）。签发配对码、列设备、设置设备权限、撤销设备。密钥只从数据目录私有文件读，不进日志。
struct HookClient: HookAdmin, Sendable {
    struct PairCode: Sendable { let code: String; let expiresT: Int }
    struct Device: Decodable, Sendable, Identifiable {
        let id: String
        let name: String
        let pairedT: Int
        let lastSeenT: Int?
        let paused: Bool
        let revoked: Bool
        /// readonly | control；旧 Bridge 没有该字段。
        let permission: String?
    }
    private struct DevicesPage: Decodable { let devices: [Device]; let next: String? }
    private struct PairResp: Decodable { let code: String; let expiresT: Int }

    enum HookError: Error { case bridgeNotRunning, unauthorized, invalidResponse, http(Int) }

    let dataDir: String
    let hookPort: Int

    private var secret: String? {
        let url = URL(fileURLWithPath: dataDir).appendingPathComponent("hook.secret")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let secret else { throw HookError.bridgeNotRunning }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(hookPort)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 5
        req.setValue("Hook \(secret)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.proxyConfigurations = []
        let (data, resp) = try await URLSession(configuration: cfg).data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw HookError.unauthorized }
        guard (200..<300).contains(code) else { throw HookError.http(code) }
        guard data.count <= 64 * 1024 else { throw HookError.invalidResponse }
        return data
    }

    func issuePairCode() async throws -> PairCode {
        let r = try JSONDecoder().decode(PairResp.self, from: try await request("POST", "/hooks/pair"))
        return PairCode(code: r.code, expiresT: r.expiresT)
    }

    func devices(all: Bool) async throws -> [Device] {
        var out: [Device] = []
        var after: String?
        for _ in 0..<20 {
            var path = "/hooks/devices?limit=100" + (all ? "&all=1" : "")
            if let after { path += "&after=\(after)" }
            let page = try JSONDecoder().decode(DevicesPage.self, from: try await request("GET", path))
            out.append(contentsOf: page.devices)
            guard let next = page.next else { break }
            after = next
        }
        return out
    }

    /// 设备权限只在本机改（设备自己没有接口能改）；新配对的设备默认只读。
    func setPermission(deviceId: String, _ permission: DevicePermission) async throws {
        struct Resp: Decodable { struct D: Decodable { let id: String; let permission: String }; let device: D }
        let body = try JSONEncoder().encode(["permission": permission.rawValue])
        let r = try JSONDecoder().decode(Resp.self, from: try await request("POST", "/hooks/devices/\(deviceId)/permission", body: body))
        guard r.device.id == deviceId, r.device.permission == permission.rawValue else { throw HookError.invalidResponse }
    }

    func remove(deviceId: String) async throws {
        struct Removed: Decodable { let removed: String }
        let r = try JSONDecoder().decode(Removed.self, from: try await request("DELETE", "/hooks/devices/\(deviceId)"))
        guard r.removed == deviceId else { throw HookError.invalidResponse }
    }
}
