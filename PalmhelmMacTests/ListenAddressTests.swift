import XCTest
@testable import PalmhelmMac

// h8 监听地址自适应：地址解析、旧 bind 迁移、重启决策（纯函数）。夹具用文档保留网段与虚构接口，不读真实网卡。
final class ListenResolverTests: XCTestCase {
    private func nic(_ name: String, _ ip: String, up: Bool = true) -> NetInterface { NetInterface(name: name, ip: ip, up: up) }

    func testLanPrefersEn0OverOtherPhysicalInterfaces() {
        XCTAssertEqual(ListenResolver.lan([nic("en1", "192.168.1.20"), nic("en0", "10.0.0.5")]), "10.0.0.5")
        XCTAssertEqual(ListenResolver.lan([nic("en5", "172.16.3.4"), nic("en1", "192.168.1.20")]), "192.168.1.20", "没有 en0：其余 en* 按名字顺序，与枚举顺序无关")
        XCTAssertEqual(ListenResolver.lan([nic("en1", "192.168.1.20"), nic("en5", "172.16.3.4")]), "192.168.1.20")
    }

    func testLanExcludesVirtualInterfaces() {
        for name in ["utun3", "bridge100", "vmnet8", "docker0", "awdl0", "llw0", "veth1", "vboxnet0", "gif0", "ap1", "ipsec0", "ppp0", "lo0"] {
            XCTAssertNil(ListenResolver.lan([nic(name, "192.168.64.1")]), "\(name) 不是同一 Wi‑Fi 的局域网")
        }
        // 虚拟口与真实口同时存在：只取真实口
        XCTAssertEqual(ListenResolver.lan([nic("bridge100", "192.168.64.1"), nic("vmnet8", "172.16.9.1"), nic("en0", "10.0.0.5")]), "10.0.0.5")
    }

    func testLanOnlyRfc1918AndInterfaceUp() {
        XCTAssertNil(ListenResolver.lan([nic("en0", "8.8.8.8")]), "公网地址不算")
        XCTAssertNil(ListenResolver.lan([nic("en0", "169.254.10.1")]), "链路本地不算")
        XCTAssertNil(ListenResolver.lan([nic("en0", "100.100.1.1")]), "CGNAT 不是局域网")
        XCTAssertNil(ListenResolver.lan([nic("en0", "172.32.0.1")]), "172.32 不在 RFC1918")
        XCTAssertEqual(ListenResolver.lan([nic("en0", "172.31.255.254")]), "172.31.255.254")
        XCTAssertNil(ListenResolver.lan([nic("en0", "192.168.1.2", up: false)]), "接口不在线不算")
        XCTAssertEqual(ListenResolver.lan([nic("en0", "192.168.1.2", up: false), nic("en1", "10.1.1.1")]), "10.1.1.1")
        XCTAssertNil(ListenResolver.lan([]))
    }

    func testTailscaleIsCgnatOnUtunOnly() {
        XCTAssertEqual(ListenResolver.tailscale([nic("utun4", "100.64.0.1")]), "100.64.0.1")
        XCTAssertEqual(ListenResolver.tailscale([nic("utun4", "100.127.255.254")]), "100.127.255.254")
        XCTAssertNil(ListenResolver.tailscale([nic("utun4", "100.63.255.255")]), "100.64/10 之外")
        XCTAssertNil(ListenResolver.tailscale([nic("utun4", "100.128.0.1")]))
        XCTAssertNil(ListenResolver.tailscale([nic("en0", "100.100.1.1")]), "不在 utun 上的 100.x 不算 Tailscale")
        XCTAssertNil(ListenResolver.tailscale([nic("utun4", "100.100.1.1", up: false)]))
        XCTAssertNil(ListenResolver.tailscale([nic("utun4", "10.0.0.2")]))
    }

    func testResolveFollowsIntentAndNeverFallsBackToAllInterfaces() {
        let ifaces = [nic("en0", "192.168.1.9"), nic("utun4", "100.100.1.1")]
        let both = ListenResolver.resolve(intent: ListenIntent(lan: true, tailscale: true), ifaces)
        XCTAssertEqual(both.bindList, ["127.0.0.1", "192.168.1.9", "100.100.1.1"])
        XCTAssertEqual(both.bind, "127.0.0.1,192.168.1.9,100.100.1.1")
        // 只勾 Tailscale：即使有局域网地址也不监听
        let tsOnly = ListenResolver.resolve(intent: ListenIntent(lan: false, tailscale: true), ifaces)
        XCTAssertEqual(tsOnly.bindList, ["127.0.0.1", "100.100.1.1"])
        XCTAssertFalse(tsOnly.lanUnavailable)
        // 什么都不勾：只有回环
        XCTAssertEqual(ListenResolver.resolve(intent: ListenIntent(lan: false, tailscale: false), ifaces).bindList, ["127.0.0.1"])
        // 勾了局域网但没有地址：不启用其他渠道、不用 0.0.0.0，标记暂不可用
        let none = ListenResolver.resolve(intent: ListenIntent(lan: true, tailscale: false), [nic("utun4", "100.100.1.1")])
        XCTAssertEqual(none.bindList, ["127.0.0.1"])
        XCTAssertTrue(none.lanUnavailable)
        XCTAssertFalse(none.bind.contains("0.0.0.0"))
        let noTs = ListenResolver.resolve(intent: ListenIntent(lan: false, tailscale: true), [nic("en0", "192.168.1.9")])
        XCTAssertEqual(noTs.bindList, ["127.0.0.1"])
        XCTAssertTrue(noTs.tailscaleUnavailable)
    }
}

final class ListenMigrationTests: XCTestCase {
    func testLegacyBindToIntent() {
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "127.0.0.1,10.0.0.5,100.64.0.7"), ListenIntent(lan: true, tailscale: true))
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "127.0.0.1"), ListenIntent(lan: false, tailscale: false))
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "127.0.0.1, 192.168.5.9"), ListenIntent(lan: true, tailscale: false))
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "100.64.0.1"), ListenIntent(lan: false, tailscale: true))
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "172.16.0.5,172.16.0.5"), ListenIntent(lan: true, tailscale: false), "重复项不影响")
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "0.0.0.0"), ListenIntent(lan: false, tailscale: false), "0.0.0.0 不折算成任何渠道")
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: "8.8.8.8"), ListenIntent(lan: false, tailscale: false))
        XCTAssertEqual(ListenMigration.intent(fromLegacyBind: ""), ListenIntent(lan: false, tailscale: false))
    }
}

/// 丢弃指定键的 Bool 写入：模拟「新值没写进去」。
private final class DroppingDefaults: UserDefaults {
    var drop: Set<String> = []
    override func set(_ value: Bool, forKey defaultName: String) {
        if drop.contains(defaultName) { return }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class ListenSettingsTests: XCTestCase {
    private var suites: [String] = []
    private func defaults<T: UserDefaults>(_ make: (String) -> T) -> T {
        let name = "palmhelm.test.h8.\(UUID().uuidString)"
        suites.append(name)
        return make(name)
    }
    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
    }

    func testMigratesOldBindOnceAndRemovesItAfterNewValuesAreReadBack() {
        let d = defaults { UserDefaults(suiteName: $0)! }
        d.set("127.0.0.1,10.0.0.5,100.64.0.7", forKey: "engine.bind")
        let s = EngineSettings(defaults: d)
        XCTAssertTrue(s.listenLan)
        XCTAssertTrue(s.listenTailscale)
        XCTAssertEqual(d.object(forKey: "listen.lan") as? Bool, true)
        XCTAssertEqual(d.object(forKey: "listen.tailscale") as? Bool, true)
        XCTAssertNil(d.object(forKey: "engine.bind"), "新值回读一致后才删旧值；迁移后不再保存具体 IP")
        // 之后任何 IP 都不会再写进存储
        s.listenLan = false
        XCTAssertFalse(d.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("10.111") == true })
        // 再次启动：沿用已保存的意图，不会被（已不存在的）旧值覆盖
        let again = EngineSettings(defaults: d)
        XCTAssertFalse(again.listenLan)
        XCTAssertTrue(again.listenTailscale)
    }

    func testFailedWriteKeepsOldValueAndStillHonoursItThisLaunch() {
        let d = defaults { DroppingDefaults(suiteName: $0)! }
        d.set("127.0.0.1,192.168.5.9", forKey: "engine.bind")
        d.drop = ["listen.lan"]
        let s = EngineSettings(defaults: d)
        XCTAssertTrue(s.listenLan, "写入失败也不丢勾选：本次由旧值折算")
        XCTAssertEqual(d.string(forKey: "engine.bind"), "127.0.0.1,192.168.5.9", "新值没写成功：旧值保留")
        XCTAssertNil(d.object(forKey: "listen.lan"))
        XCTAssertNil(d.object(forKey: "listen.tailscale"), "半写入的新值被清掉，下次启动会重试迁移")
        // 下次启动写入恢复正常：迁移成功并删除旧值
        d.drop = []
        let next = EngineSettings(defaults: d)
        XCTAssertTrue(next.listenLan)
        XCTAssertNil(d.object(forKey: "engine.bind"))
    }

    func testExplicitIntentIsNeverOverwrittenByLegacyBind() {
        let d = defaults { UserDefaults(suiteName: $0)! }
        d.set(false, forKey: "listen.lan")
        d.set(true, forKey: "listen.tailscale")
        d.set("127.0.0.1,192.168.5.9", forKey: "engine.bind")
        let s = EngineSettings(defaults: d)
        XCTAssertFalse(s.listenLan)
        XCTAssertTrue(s.listenTailscale)
    }

    func testFreshInstallDefaultsToLoopbackOnly() {
        let s = EngineSettings(defaults: defaults { UserDefaults(suiteName: $0)! })
        s.interfaceProvider = { [NetInterface(name: "en0", ip: "192.168.1.9")] }
        XCTAssertFalse(s.listenLan)
        XCTAssertFalse(s.listenTailscale)
        XCTAssertEqual(s.bind, "127.0.0.1")
    }

    func testEnvironmentUsesResolvedAddressesAndFrozenResolution() {
        let s = EngineSettings(defaults: defaults { UserDefaults(suiteName: $0)! })
        s.listenLan = true
        s.tls = true
        s.interfaceProvider = { [NetInterface(name: "en0", ip: "192.168.1.9")] }
        XCTAssertEqual(s.environment()["BRIDGE_LOCAL_API_BIND"], "127.0.0.1,192.168.1.9")
        // 换了 Wi‑Fi 之后：同一份冻结的解析得到同一个环境（所以网络变化本身不算「设置有更改」）
        let frozen = s.resolvedListen()
        s.interfaceProvider = { [NetInterface(name: "en0", ip: "10.9.9.9")] }
        XCTAssertEqual(s.environment(resolution: frozen), s.environment(resolution: frozen))
        XCTAssertEqual(s.environment(resolution: frozen)["BRIDGE_LOCAL_API_BIND"], "127.0.0.1,192.168.1.9")
        XCTAssertEqual(s.environment()["BRIDGE_LOCAL_API_BIND"], "127.0.0.1,10.9.9.9")
    }

    func testNoLanAddressIsNotAStartupProblem() {
        let s = EngineSettings(defaults: defaults { UserDefaults(suiteName: $0)! })
        s.listenLan = true
        s.tls = true
        s.interfaceProvider = { [] }
        XCTAssertNil(s.listenProblem, "勾了局域网但暂时没有地址：启动不失败，只在状态区提示")
        XCTAssertEqual(s.bind, "127.0.0.1")
        XCTAssertTrue(s.resolvedListen().lanUnavailable)
        s.tls = false
        XCTAssertNotNil(s.listenProblem, "https 是配置要求，与有没有地址无关（保证网络恢复后自动重启不会因此失败）")
    }

    func testTailscaleHostnameOnlyRequiredWhenAddressResolved() {
        let s = EngineSettings(defaults: defaults { UserDefaults(suiteName: $0)! })
        s.listenTailscale = true
        s.tls = true
        s.hostnames = ""
        s.interfaceProvider = { [] }
        XCTAssertNil(s.listenProblem, "Tailscale 暂不可用时不因主机名阻止启动")
        s.interfaceProvider = { [NetInterface(name: "utun4", ip: "100.100.1.1")] }
        XCTAssertNotNil(s.listenProblem)
        s.hostnames = "my-mac.tail1234.ts.net"
        XCTAssertNil(s.listenProblem)
    }

    func testEnvImportConvertsLegacyBindToIntentAndStoresNoIP() throws {
        let d = defaults { UserDefaults(suiteName: $0)! }
        let s = EngineSettings(defaults: d)
        let path = NSTemporaryDirectory() + "palmhelm-h8-\(UUID().uuidString).env"
        try "BRIDGE_LOCAL_API_BIND=127.0.0.1,192.168.5.9,100.64.0.9\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try s.importEnvFile(at: path)
        XCTAssertTrue(s.listenLan)
        XCTAssertTrue(s.listenTailscale)
        XCTAssertNil(d.object(forKey: "engine.bind"))
    }
}

final class ListenWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let both = ListenIntent(lan: true, tailscale: true)
    private func res(_ lan: String?, _ ts: String?, intent: ListenIntent? = nil) -> ListenResolution {
        ListenResolution(lan: lan, tailscale: ts, intent: intent ?? both)
    }
    /// 启动于 t0 之前 60 秒（已过限频窗口），除非用例特别需要
    private func watch(lan: String? = "192.168.1.9", ts: String? = "100.100.1.1", intent: ListenIntent? = nil, startedAgo: TimeInterval = 60) -> ListenWatch {
        ListenWatch(started: res(lan, ts, intent: intent), at: t0.addingTimeInterval(-startedAgo))
    }

    func testUnchangedNeverRestarts() {
        var w = watch()
        XCTAssertEqual(w.observe(res("192.168.1.9", "100.100.1.1"), now: t0), .none)
        XCTAssertEqual(w.observe(res("192.168.1.9", "100.100.1.1"), now: t0.addingTimeInterval(600)), .none)
    }

    func testChangeWaitsForDebounceThenRestarts() {
        var w = watch()
        let changed = res("10.9.9.9", "100.100.1.1")
        XCTAssertEqual(w.observe(changed, now: t0), .wait(until: t0.addingTimeInterval(3)))
        XCTAssertEqual(w.observe(changed, now: t0.addingTimeInterval(2.9)), .wait(until: t0.addingTimeInterval(3)))
        XCTAssertEqual(w.observe(changed, now: t0.addingTimeInterval(3)), .restart)
    }

    func testFurtherChangeWithinDebounceRestartsTheTimer() {
        var w = watch()
        XCTAssertEqual(w.observe(res("10.9.9.9", "100.100.1.1"), now: t0), .wait(until: t0.addingTimeInterval(3)))
        // 2 秒后又换了一个地址：重新计时
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.1.1"), now: t0.addingTimeInterval(2)), .wait(until: t0.addingTimeInterval(5)))
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.1.1"), now: t0.addingTimeInterval(4.9)), .wait(until: t0.addingTimeInterval(5)))
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.1.1"), now: t0.addingTimeInterval(5)), .restart)
    }

    func testChangeThatRevertsBeforeDebounceNeverRestarts() {
        var w = watch()
        XCTAssertEqual(w.observe(res("10.9.9.9", "100.100.1.1"), now: t0), .wait(until: t0.addingTimeInterval(3)))
        XCTAssertEqual(w.observe(res("192.168.1.9", "100.100.1.1"), now: t0.addingTimeInterval(1)), .none)
        // 之后即使时间走过原来的到点时间，也不重启
        XCTAssertEqual(w.observe(res("192.168.1.9", "100.100.1.1"), now: t0.addingTimeInterval(10)), .none)
    }

    func testEmptyAddressIsTransientAndDoesNotRestart() {
        var w = watch()
        // 关 Wi‑Fi：局域网地址为空（已勾选渠道暂时解析不到）→ 沿用已绑定值
        XCTAssertEqual(w.observe(res(nil, "100.100.1.1"), now: t0), .none)
        XCTAssertEqual(w.observe(res(nil, nil), now: t0.addingTimeInterval(30)), .none)
        XCTAssertEqual(w.observe(res(nil, nil), now: t0.addingTimeInterval(60)), .none, "离线 1 分钟：不反复重启")
        // 恢复成同一个地址：不重启
        XCTAssertEqual(w.observe(res("192.168.1.9", "100.100.1.1"), now: t0.addingTimeInterval(61)), .none)
    }

    func testRecoveryWithDifferentAddressRestartsOnce() {
        var w = watch()
        XCTAssertEqual(w.observe(res(nil, "100.100.1.1"), now: t0), .none)
        let back = res("10.0.0.77", "100.100.1.1")
        XCTAssertEqual(w.observe(back, now: t0.addingTimeInterval(60)), .wait(until: t0.addingTimeInterval(63)))
        XCTAssertEqual(w.observe(back, now: t0.addingTimeInterval(63)), .restart)
    }

    func testRestartsAreRateLimitedToOnePerThirtySeconds() {
        // 启动于 5 秒前：变化的防抖 3 秒到点时仍在 30 秒限频内 → 等到启动后 30 秒
        var w = watch(startedAgo: 5)
        let changed = res("10.9.9.9", "100.100.1.1")
        XCTAssertEqual(w.observe(changed, now: t0), .wait(until: t0.addingTimeInterval(3)))
        XCTAssertEqual(w.observe(changed, now: t0.addingTimeInterval(3)), .wait(until: t0.addingTimeInterval(25)), "距启动 30 秒（= t0 + 25）前一直等")
        XCTAssertEqual(w.observe(changed, now: t0.addingTimeInterval(24.9)), .wait(until: t0.addingTimeInterval(25)))
        XCTAssertEqual(w.observe(changed, now: t0.addingTimeInterval(25)), .restart)
    }

    func testNewWatchAfterRestartStartsFreshLimitWindow() {
        // 重启后新的 watch 以新地址为已绑定值，限频窗口从新启动算起
        var w = ListenWatch(started: res("10.9.9.9", "100.100.1.1"), at: t0)
        XCTAssertEqual(w.observe(res("10.9.9.9", "100.100.1.1"), now: t0.addingTimeInterval(1)), .none)
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.1.1"), now: t0.addingTimeInterval(2)), .wait(until: t0.addingTimeInterval(5)))
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.1.1"), now: t0.addingTimeInterval(5)), .wait(until: t0.addingTimeInterval(30)), "上次启动后 30 秒内最多再重启一次")
    }

    func testTailscaleOnlyIgnoresLanChanges() {
        let intent = ListenIntent(lan: false, tailscale: true)
        var w = watch(lan: nil, ts: "100.100.1.1", intent: intent)
        // 换 Wi‑Fi（局域网地址变化）：不重启、不新增监听
        XCTAssertEqual(w.observe(res("10.9.9.9", "100.100.1.1", intent: intent), now: t0), .none)
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.1.1", intent: intent), now: t0.addingTimeInterval(100)), .none)
        // Tailscale 地址变了才重启
        XCTAssertEqual(w.observe(res("172.16.0.7", "100.100.2.2", intent: intent), now: t0.addingTimeInterval(200)), .wait(until: t0.addingTimeInterval(203)))
    }

    func testChannelsNotCheckedAtStartNeverTriggerEvenIfUserNowChecksThem() {
        // 启动时只勾了局域网：之后 Tailscale 出现地址不触发（用户改勾选走「设置有更改」流程，不由网络监测处理）
        let intent = ListenIntent(lan: true, tailscale: false)
        var w = watch(ts: nil, intent: intent)
        XCTAssertEqual(w.observe(res("192.168.1.9", "100.100.1.1", intent: ListenIntent(lan: true, tailscale: true)), now: t0), .none)
    }

    func testLanAppearingAfterStartedWithoutOneRestartsAfterDebounce() {
        // 启动时勾了局域网但没有地址（场景 6），之后连上 Wi‑Fi：一次重启把它监听起来
        var w = watch(lan: nil, ts: nil)
        let up = res("192.168.1.9", nil)
        XCTAssertEqual(w.observe(up, now: t0), .wait(until: t0.addingTimeInterval(3)))
        XCTAssertEqual(w.observe(up, now: t0.addingTimeInterval(3)), .restart)
    }

    func testSleepWakeBurstWithSameAddressesDoesNotRestart() {
        var w = watch()
        // 唤醒瞬间：接口短暂缺失，随后恢复成原地址；中途任意多次路径事件
        let seq: [ListenResolution] = [res(nil, nil), res(nil, "100.100.1.1"), res("192.168.1.9", nil), res("192.168.1.9", "100.100.1.1")]
        for (i, r) in seq.enumerated() { XCTAssertEqual(w.observe(r, now: t0.addingTimeInterval(Double(i))), .none) }
    }
}
