// 菜单栏 App 的数据层：常驻一条 BLE 连接，耳机推送的变化实时反映到界面
import Foundation
import ServiceManagement

@MainActor
final class BudsModel: ObservableObject {
    @Published var state = BudsState()
    @Published var phase: BudsLink.Phase = .idle
    @Published var name = "小米耳机"
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let link = BudsLink()
    private var timer: Timer?
    private var tick = 0

    init() {
        link.onPhase = { [weak self] p in
            MainActor.assumeIsolated { self?.phase = p }
        }
        link.onAuthed = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.name = self.link.name ?? "小米耳机"
                self.link.requestStatus()
            }
        }
        link.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state = self.link.state
            }
        }
        link.start()
        // 没连上时每 5 秒找一次耳机；连上后每分钟刷新一次电量
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
    }

    private func heartbeat() {
        tick += 1
        if phase == .ready {
            if tick % 12 == 0 { link.requestStatus() }
        } else if phase != .connecting && phase != .searching {
            link.start()
        }
    }

    func refresh() {
        if phase == .ready { link.requestStatus() } else { link.start() }
    }

    // 发命令后稍等再读一次，拿到耳机确认后的真实状态
    private func send(_ commands: [[UInt8]]) {
        guard phase == .ready else { return }
        for c in commands { link.command(c) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.link.requestStatus()
        }
    }

    private func config(_ id: UInt16) -> [UInt8]? { state.configs[id] }
    // 耳机回过这个配置项才显示对应控件，别的型号不支持的功能就自动藏起来
    func has(_ id: UInt16) -> Bool { state.configs[id] != nil }
    private func flag(_ id: UInt16) -> Bool { config(id)?.first == 1 }

    // MARK: 读

    var battery: (left: UInt8?, right: UInt8?, box: UInt8?) {
        let b = state.battery
        func v(_ i: Int) -> UInt8? { i < b.count && b[i] != 0xFF ? b[i] : nil }
        return (v(0), v(1), v(2))
    }

    var lowestBattery: Int? {
        let vals = [battery.left, battery.right].compactMap { $0 }.map { Int($0 & 0x7F) }
        return vals.min()
    }

    var mode: UInt8 { state.mode ?? 0 }
    var ancLevel: Double {
        if let c = config(0x0B), c.count >= 2, c[0] == 1 { return Double(c[1]) }
        return 19
    }
    var transLevel: UInt8 {
        if let c = config(0x0B), c.count >= 2, c[0] == 2 { return c[1] }
        return 0
    }
    var adaptiveAnc: Bool { flag(0x25) }
    var personalAnc: Bool { flag(0x3B) }
    var eq: UInt8 { config(0x07)?.first ?? 0 }
    var spatialBits: UInt8 { config(0x1E)?.first ?? 0 }
    var scene: UInt8 {
        guard let c = config(0x36), c.first == 1, c.count >= 2 else { return 0 }
        return c[1]
    }
    var adaptiveSense: Bool { flag(0x29) }
    var adaptiveVolume: Bool { flag(0x48) }
    var autoAnswer: Bool { flag(0x03) }
    var dual: Bool { flag(0x04) }
    var wearDetect: Bool { state.wearDetect ?? false }
    var hotword: Bool { state.hotword ?? false }
    var freeTalk: UInt8 {
        guard let c = config(0x0D), c.count >= 2, c[0] == 1 else { return 0 }
        return c[1]
    }

    // 手势：类型 → 左右动作
    func gesture(_ type: UInt8) -> (left: UInt8, right: UInt8)? {
        guard let g = config(0x02) else { return nil }
        var i = 0
        while i + 2 < g.count {
            if g[i] == type { return (g[i + 1], g[i + 2]) }
            i += 3
        }
        return nil
    }

    // MARK: 写（先改本地状态让界面立刻跟手，再发给耳机）

    func setMode(_ m: UInt8) {
        state.mode = m
        send([vendorSet(0x04, m)])
    }

    func setAncLevel(_ v: Double) {
        let lv = UInt8(v.rounded())
        state.configs[0x0B] = [1, lv]
        state.configs[0x25] = [0]
        send([setConfig(0x25, [0]), setConfig(0x0B, [1, lv])])
    }

    func setAdaptiveAnc(_ on: Bool) {
        state.configs[0x25] = [on ? 1 : 0]
        send([setConfig(0x25, [on ? 1 : 0])])
    }

    func setTransLevel(_ v: UInt8) {
        state.configs[0x0B] = [2, v]
        send([setConfig(0x0B, [2, v])])
    }

    func setSwitch(_ id: UInt8, _ on: Bool) {
        state.configs[UInt16(id)] = [on ? 1 : 0]
        send([setConfig(id, [on ? 1 : 0])])
    }

    func setEq(_ v: UInt8) {
        state.configs[0x07] = [v]
        send([setConfig(0x07, [v])])
    }

    func setSpatial(_ change: (UInt8) -> UInt8) {
        let v = change(spatialBits)
        state.configs[0x1E] = [v]
        send([setConfig(0x1D, [v])])
    }

    func setScene(_ v: UInt8) {
        state.configs[0x36] = v == 0 ? [0] : [1, v]
        send([setConfig(0x36, v == 0 ? [0] : [1, v])])
    }

    func setWearDetect(_ on: Bool) {
        state.wearDetect = on
        // 注意是反的：0 开、1 关
        send([vendorSet(0x06, on ? 0 : 1)])
    }

    func setHotword(_ on: Bool) {
        state.hotword = on
        send([vendorSet(0x02, on ? 1 : 0)])
    }

    func setFreeTalk(_ v: UInt8) {
        state.configs[0x0D] = v == 0 ? [0, 0] : [1, v]
        send([setConfig(0x0D, v == 0 ? [0, 0] : [1, v])])
    }

    func setGesture(_ type: UInt8, _ action: UInt8) {
        send([setConfig(0x02, [type, action, action])])
    }

    func find(_ on: Bool) {
        send([setConfig(0x09, [on ? 1 : 0, 3])])
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("开机自启设置失败: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
