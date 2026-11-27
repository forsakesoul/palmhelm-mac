import XCTest
import PalmhelmKit
@testable import PalmhelmMac

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
private func decode<T: Decodable>(_ json: String) -> T { try! JSONDecoder().decode(T.self, from: Data(json.utf8)) }

/// 假本机管理口：记录撤销了谁，不碰真实 Bridge。
private final class FakeHook: HookAdmin, @unchecked Sendable {
    let list: Box<[HookClient.Device]>
    let removed = Box<[String]>([])
    let issued = Box(0)
    let listFails: Bool
    init(_ devices: [HookClient.Device], listFails: Bool = false) { list = Box(devices); self.listFails = listFails }
    func issuePairCode() async throws -> HookClient.PairCode { issued.value += 1; return HookClient.PairCode(code: "123456", expiresT: 0) }
    func setPermission(deviceId: String, _ permission: DevicePermission) async throws {}
    let listCalls = Box(0)
    func devices(all: Bool) async throws -> [HookClient.Device] { listCalls.value += 1; if listFails { throw URLError(.cannotConnectToHost) }; return list.value }
    func remove(deviceId: String) async throws { removed.value.append(deviceId) }
}

private func readonlyState() -> BridgeState {
    decode(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]},"device":{"id":"d1","name":"mac","paused":false,"permission":"readonly"}}"#)
}

private func device(_ id: String, name: String, revoked: Bool = false) -> HookClient.Device {
    decode(#"{"id":"\#(id)","name":"\#(name)","pairedT":1,"lastSeenT":null,"paused":false,"revoked":\#(revoked)}"#)
}

private actor GateX {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// h13：测试宿主隔离（不碰真实钥匙串 / 偏好）与自配对不累积。
@MainActor
final class SelfPairingTests: XCTestCase {
    override func setUp() { KeychainStore.delete(account: KeychainStore.tokenAccount) }
    override func tearDown() { KeychainStore.delete(account: KeychainStore.tokenAccount) }

    private let httpsA = BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: "SPKI-A")

    private func state() -> BridgeState {
        decode(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}}"#)
    }
    private func session(stateError: Error? = nil) -> MacSession {
        let s = MacSession()
        s.streamDisabled = true
        s.stateOverride = { [unowned s] in if let e = stateError { throw e }; return await MainActor.run { s.state ?? BridgeState.empty } }
        return s
    }
    private func paired(_ s: MacSession, at ep: BridgeEndpoint) async {
        KeychainStore.save("old-token", account: KeychainStore.tokenAccount)
        await s.loadCredentials()
        s.endpoint = ep
    }
    private func counted(_ s: MacSession, hook: FakeHook = FakeHook([])) -> (pairs: Box<Int>, hook: FakeHook) {
        let pairs = Box(0)
        s.hookFactory = { _, _ in hook }
        s.pairOverride = { ep, code, name in
            pairs.value += 1
            return decode(#"{"deviceId":"new","token":"new-token","spkiSha256":"\#(ep.spkiSha256 ?? "")"}"#)
        }
        return (pairs, hook)
    }

    // MARK: 1 测试隔离

    func testTestHostNeverTouchesTheRealKeychainOrStandardDefaults() async {
        XCTAssertTrue(RuntimeEnvironment.isTestHost)
        XCTAssertTrue(KeychainStore.usesMemoryBackend, "测试宿主下钥匙串走内存")
        XCTAssertFalse(AppDefaults.standard === UserDefaults.standard, "偏好走独立 suite")
        let keys = ["bridge.host", "bridge.port", "bridge.transport", "bridge.spki", "palmhelm.lens", "palmhelm.themeFamily", "palmhelm.appearance"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        let s = session()
        KeychainStore.saveEndpoint(httpsA)
        KeychainStore.save("tok", account: KeychainStore.tokenAccount)
        XCTAssertEqual(KeychainStore.loadEndpoint(), httpsA, "写进了隔离的存储")
        XCTAssertEqual(AppDefaults.standard.string(forKey: "bridge.host"), "192.168.1.9")
        s.lens = .inbox
        s.forget() // 曾经会删掉真实 App 的端点与设备令牌
        XCTAssertNil(KeychainStore.loadEndpoint())
        XCTAssertNil(KeychainStore.load(account: KeychainStore.tokenAccount))
        let after = keys.map { UserDefaults.standard.object(forKey: $0) as? NSObject }
        XCTAssertEqual(before, after, "真实 UserDefaults.standard 的 bridge.* / lens / 主题键一个都没变")
    }

    func testEngineSettingsAndThemeDefaultToTheIsolatedSuiteInTestHost() {
        let s = EngineSettings(secretsReady: true)
        let key = "engine.pricingAutoUpdate"
        let before = UserDefaults.standard.object(forKey: key) as? NSObject
        s.pricingAutoUpdate.toggle()
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? NSObject, before, "默认偏好落在独立 suite，不改真实 App 的值")
        XCTAssertNotNil(AppDefaults.standard.object(forKey: key))
        s.pricingAutoUpdate.toggle()
    }

    // MARK: 2 自配对清理旧记录

    /// O1-364 R6：只撤销本机记录的上一台设备（deviceId 已知）；同名的其他 Mac / iPhone 绝不撤销。
    func testSelfPairRevokesOnlyTheRecordedPreviousSelfDevice() async {
        let s = session()
        s.preferences.set("old1", forKey: MacSession.selfDeviceIdKey)
        let name = s.deviceName
        let hook = FakeHook([
            device("old1", name: name), device("old2", name: name),
            device("phone", name: "Mac"), device("other-mac", name: "Mac"),
            device("gone", name: name, revoked: true), device("new", name: name),
        ])
        let (pairs, _) = counted(s, hook: hook)
        await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs.value, 1)
        XCTAssertEqual(hook.removed.value, ["old1"], "只撤销记录的上一台本机设备；同名的 old2 / 叫 Mac 的其他设备都保留")
        XCTAssertEqual(s.preferences.string(forKey: MacSession.selfDeviceIdKey), "new", "新的 deviceId 登记为本机记录")
    }

    /// 没有记录（升级前的旧版本或身份不明）时不撤销任何设备：显示名不能决定撤销身份。
    func testUnknownPreviousIdentityKeepsEverySameNameDevice() async {
        let s = session()
        s.preferences.removeObject(forKey: MacSession.selfDeviceIdKey)
        let name = s.deviceName
        let hook = FakeHook([device("old1", name: name), device("other-mac", name: "Mac")])
        _ = counted(s, hook: hook)
        await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(hook.removed.value, [], "身份不明：全部保留，交给用户管理")
    }

    func testPruneFailureDoesNotBreakTheNewPairing() async {
        let s = session()
        s.state = state()
        s.preferences.set("old1", forKey: MacSession.selfDeviceIdKey)     // 有上一台记录，清理会去查设备列表
        let hook = FakeHook([], listFails: true)
        _ = counted(s, hook: hook)
        await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(hook.listCalls.value, 1, "清理确实去拿了设备列表（失败分支被执行）")
        XCTAssertEqual(KeychainStore.load(account: KeychainStore.tokenAccount), "new-token")
        XCTAssertEqual(s.link, .connected, "清理失败不影响本次配对")
    }

    // MARK: 3 不必要的重配

    func testNetworkErrorOnRefreshDoesNotSelfPair() async {
        let s = session(stateError: URLError(.cannotConnectToHost))
        await paired(s, at: httpsA)
        let (pairs, hook) = counted(s)
        await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs.value, 0, "网络 / 时序离线不新签码")
        XCTAssertEqual(hook.issued.value, 0)
        XCTAssertFalse(s.refreshAuthFailed)
        if case .offline = s.link {} else { XCTFail("应是离线：\(s.link)") }
        XCTAssertEqual(KeychainStore.load(account: KeychainStore.tokenAccount), "old-token", "令牌保留")
    }

    func testServerErrorOnRefreshDoesNotSelfPairEither() async {
        let s = session(stateError: BridgeError.http(status: 503))
        await paired(s, at: httpsA)
        let (pairs, _) = counted(s)
        await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs.value, 0)
    }

    func testAuthFailureSelfPairsOnceFor401And403() async {
        for code in [401, 403] {
            let s = session(stateError: BridgeError.http(status: code))
            await paired(s, at: httpsA)
            let (pairs, hook) = counted(s)
            await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
            XCTAssertEqual(pairs.value, 1, "\(code)：令牌无效 / 设备已撤销才重新自配对")
            XCTAssertEqual(hook.issued.value, 1)
        }
    }

    func testSameSpkiDifferentPortReusesTheTokenAndUpdatesTheEndpoint() async {
        let s = session()
        s.state = state()
        await paired(s, at: httpsA)
        let moved = BridgeEndpoint(host: "192.168.1.20", port: 47900, transport: .https, spkiSha256: "SPKI-A")
        let (pairs, hook) = counted(s)
        await s.ensurePaired(want: moved, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs.value, 0, "同证书换 host / 端口：不重配")
        XCTAssertEqual(hook.issued.value, 0)
        XCTAssertEqual(s.endpoint, moved)
        XCTAssertEqual(KeychainStore.loadEndpoint(), moved, "端点更新并保存")
        XCTAssertEqual(KeychainStore.load(account: KeychainStore.tokenAccount), "old-token", "复用原令牌")
        XCTAssertEqual(s.link, .connected)
    }

    func testDifferentSpkiOrTransportStillSelfPairs() async {
        let s = session()
        s.state = state()
        await paired(s, at: httpsA)
        let (pairs, _) = counted(s)
        await s.ensurePaired(want: BridgeEndpoint(host: "192.168.1.9", port: 47821, transport: .https, spkiSha256: "SPKI-B"), hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs.value, 1, "证书身份变了：必须重新配对")
        let s2 = session()
        s2.state = state()
        await paired(s2, at: httpsA)
        let (pairs2, _) = counted(s2)
        await s2.ensurePaired(want: BridgeEndpoint(host: "127.0.0.1", port: 47821, transport: .http, spkiSha256: nil), hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs2.value, 1, "传输变了（https→http）：重新配对")
    }

    func testNoTokenSelfPairsOnce() async {
        let s = session()
        s.state = state()
        let (pairs, _) = counted(s)
        await s.ensurePaired(want: httpsA, hookPort: 1, dataDir: "/tmp/none")
        XCTAssertEqual(pairs.value, 1)
    }

    // MARK: A1-067 R1 device 独立版本号：旧的 GET state 不覆盖较新的 SSE device 帧

    private func stateJSON(device d: String?) -> BridgeState {
        let dev = d.map { #","device":{"id":"d1","name":"mac","paused":false,"permission":"\#($0)"}"# } ?? ""
        return decode(#"{"bridge":{"id":"b1"},"occupancy":"free","targets":[],"history":{"highWater":0,"items":[]}\#(dev)}"#)
    }
    private func deviceInfo(_ permission: String) -> DeviceInfo { decode(#"{"id":"d1","name":"mac","paused":false,"permission":"\#(permission)"}"#) }

    func testOlderStateResponseDoesNotOverwriteANewerDeviceFrame() async {
        let gate = GateX()
        let s = MacSession()
        s.streamDisabled = true
        s.stateOverride = { await gate.wait(); return readonlyState() } // 旧响应：device = readonly
        KeychainStore.save("tok", account: KeychainStore.tokenAccount)
        await s.loadCredentials()
        s.endpoint = httpsA
        s.device = deviceInfo("readonly")
        let pulling = Task { @MainActor in await s.refresh() } // GET 挂起（开始时 revision = 0）
        for _ in 0..<30 { await Task.yield() }
        s.applyDeviceFrame(deviceInfo("control")) // 先送来较新的 SSE 帧
        XCTAssertTrue(s.canControl)
        await gate.release() // 再放行旧响应
        await pulling.value
        XCTAssertEqual(s.device?.permission, "control", "旧响应不覆盖较新的帧")
        XCTAssertEqual(s.state?.device?.permission, "control", "state.device 也保持一致")
        XCTAssertTrue(s.canControl)
        KeychainStore.delete(account: KeychainStore.tokenAccount)
    }

    func testStateResponseStillWritesDeviceWhenNoNewerFrameArrived() async {
        let s = MacSession()
        s.streamDisabled = true
        s.stateOverride = { readonlyState() }
        KeychainStore.save("tok", account: KeychainStore.tokenAccount)
        await s.loadCredentials()
        s.endpoint = httpsA
        s.device = deviceInfo("control")
        await s.refresh()
        XCTAssertEqual(s.device?.permission, "readonly", "没有更新的帧：以权威 state 为准")
        XCTAssertEqual(s.state?.device?.permission, "readonly")
        KeychainStore.delete(account: KeychainStore.tokenAccount)
    }

    func testDeviceFrameForAnotherDeviceIsIgnoredAndRevisionStays() {
        let s = MacSession()
        s.device = deviceInfo("readonly")
        let rev = s.deviceRevision
        s.applyDeviceFrame(decode(#"{"id":"other","name":"x","paused":false,"permission":"control"}"#))
        XCTAssertEqual(s.device?.permission, "readonly")
        XCTAssertEqual(s.deviceRevision, rev)
    }

}
