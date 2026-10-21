// buds：在 Mac 上切换小米耳机的降噪 / 通透 / 关闭，查看电量和当前模式
// 协议参考 Gadgetbridge 的 Redmi Buds 实现（FE DC BA 帧 + 挑战-应答认证）。
// macOS 上经典蓝牙 RFCOMM 打不开，改走 BLE：小米耳机 App 的 aivsbluetoothsdk 用服务 AF00，写 AF07、订阅 AF08，帧格式与 RFCOMM 相同
import CoreBluetooth
import Foundation

// MARK: - 认证算法（照搬 Gadgetbridge Authentication.java）

func modPow(_ base: Int, _ exp: Int, _ mod: Int) -> Int {
    var result = 1, b = base % mod, e = exp
    while e > 0 {
        if e & 1 == 1 { result = result * b % mod }
        b = b * b % mod
        e >>= 1
    }
    return result
}

let authPattern = 0x9999
let authSeq: [UInt8] = [0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33, 0x22, 0x11, 0x11, 0x22, 0x33, 0x33]
let authCoef: [[UInt8]] = [
    [2,1,1,1,4,2,1,1,2,2,4,2,4,4,16,8], [2,1,1,1,4,2,1,1,1,1,2,1,2,2,8,4],
    [1,1,4,2,2,2,4,2,16,8,4,4,2,1,1,1], [1,1,4,2,1,1,2,1,8,4,2,2,2,1,1,1],
    [16,8,2,2,4,2,4,4,1,1,4,2,1,1,2,1], [8,4,1,1,2,1,2,2,1,1,4,2,1,1,2,1],
    [2,2,4,2,4,4,16,8,2,1,1,1,4,2,1,1], [1,1,2,1,2,2,8,4,2,1,1,1,4,2,1,1],
    [4,2,4,4,16,8,2,2,1,1,2,1,1,1,4,2], [2,1,2,2,8,4,1,1,1,1,2,1,1,1,4,2],
    [4,4,16,8,1,1,2,1,4,2,1,1,4,2,2,2], [2,2,8,4,1,1,2,1,4,2,1,1,2,1,1,1],
    [1,1,2,1,1,1,4,2,4,4,16,8,2,2,4,2], [1,1,2,1,1,1,4,2,2,2,8,4,1,1,2,1],
    [4,2,1,1,2,1,1,1,4,2,2,2,16,8,4,4], [4,2,1,1,2,1,1,1,2,1,1,1,8,4,2,2],
]

let biasMatrix: [[UInt8]] = (0..<16).map { i in
    (0..<16).map { j in
        let exponent = 17 * (i + 2) + (j + 1)
        let v = modPow(45, modPow(45, exponent, 257), 257)
        return UInt8(v == 256 ? 0 : v)
    }
}
let expTab: [UInt8] = (0..<256).map { i in i == 128 ? 0 : UInt8(modPow(45, i, 257)) }
let logTab: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 256)
    t[0] = 128
    for i in 1..<256 {
        let v = modPow(45, i, 257)
        if v != 256 { t[v] = UInt8(i) }
    }
    return t
}()

func isXor(_ i: Int) -> Bool { (1 << i) & authPattern != 0 }

func challengeResponse(_ challenge: [UInt8]) -> [UInt8] {
    var keyInit = challenge
    keyInit[15] ^= 6
    var keys: [[UInt8]] = [keyInit]
    var reg = keyInit
    reg.append(keyInit.reduce(0, ^))
    for k in 1...16 {
        for i in 0..<17 { reg[i] = (reg[i] >> 5) | (reg[i] << 3) }
        keys.append((0..<16).map { i in reg[(k + i) % 17] &+ biasMatrix[k - 1][i] })
    }

    let plain = authSeq
    var c = plain
    for round in 0..<8 {
        if round == 2 {
            for i in 0..<16 { c[i] = isXor(i) ? c[i] ^ plain[i] : c[i] &+ plain[i] }
        }
        for i in 0..<16 { c[i] = isXor(i) ? c[i] ^ keys[round * 2][i] : c[i] &+ keys[round * 2][i] }
        for i in 0..<16 { c[i] = isXor(i) ? expTab[Int(c[i])] : logTab[Int(c[i])] }
        for i in 0..<16 { c[i] = isXor(i) ? keys[round * 2 + 1][i] &+ c[i] : keys[round * 2 + 1][i] ^ c[i] }
        let copy = c
        for i in 0..<16 {
            var sum: UInt8 = 0
            for j in 0..<16 { sum = sum &+ authCoef[i][j] &* copy[j] }
            c[i] = sum
        }
    }
    for i in 0..<16 { c[i] = isXor(i) ? keys[16][i] ^ c[i] : keys[16][i] &+ c[i] }
    return c
}

// MARK: - 报文

enum MsgType: UInt8 { case phoneRequest = 0xC4, response = 0x04, budsRequest = 0xC0, budsNotify = 0xC7 }
enum Op: UInt8 {
    case deviceInfo = 0x02, anc = 0x08, runInfo = 0x09, reportStatus = 0x0E
    case authChallenge = 0x50, authConfirm = 0x51, setConfig = 0xF2, getConfig = 0xF3, notifyConfig = 0xF4
}

struct Msg {
    let type: UInt8
    let op: UInt8
    let seq: UInt8
    let payload: [UInt8]

    var isRequest: Bool { type & 0x40 != 0 }

    func encode() -> [UInt8] {
        let extra = isRequest ? 1 : 2
        let len = payload.count + extra
        var out: [UInt8] = [0xFE, 0xDC, 0xBA, type, op, UInt8(len >> 8), UInt8(len & 0xFF)]
        if !isRequest { out.append(0x00) }
        out.append(seq)
        out += payload
        out.append(0xEF)
        return out
    }

    static func split(_ data: [UInt8]) -> [Msg] {
        var starts: [Int] = []
        var i = 0
        while i + 2 < data.count {
            if data[i] == 0xFE && data[i + 1] == 0xDC && data[i + 2] == 0xBA { starts.append(i) }
            i += 1
        }
        return starts.enumerated().compactMap { idx, s in
            let end = idx + 1 < starts.count ? starts[idx + 1] : data.count
            let m = Array(data[s..<end])
            guard m.count >= 7 else { return nil }
            let type = m[3], op = m[4]
            let payloadOffset = 3 + ((type & 0x40 != 0) ? 5 : 6)
            guard m.count > payloadOffset else { return nil }
            return Msg(type: type, op: op, seq: m[payloadOffset - 1], payload: Array(m[payloadOffset..<(m.count - 1)]))
        }
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

// MARK: - 状态

// 取值表来自小米耳机 App 1.25.1 逆向（见 PROTOCOL.md）；降噪/通透档位表来自 App 日志里云端下发的 tws_gear
let modeNames: [UInt8: String] = [0: "关闭", 1: "降噪", 2: "通透"]
let transLevelNames: [UInt8: String] = [0: "标准", 1: "人声增强", 2: "环境增强"]
let eqTable: [(key: String, value: UInt8, name: String)] = [
    ("default", 0x00, "默认"), ("voice", 0x01, "人声增强"), ("bass", 0x05, "低音增强"), ("treble", 0x06, "高音增强"),
    ("volume", 0x07, "音量增强"), ("custom", 0x0A, "自定义"), ("classic", 0x0B, "经典听感"), ("legend", 0x0C, "传奇听感"),
    ("soothing", 0x0D, "低音舒缓"), ("harman", 0x0E, "哈曼 AudioEFX"), ("harman-master", 0x0F, "哈曼大师"),
]
let gestureTypes: [(key: String, value: UInt8, name: String)] = [
    ("double", 1, "双击"), ("triple", 2, "三击"), ("long", 3, "长按"), ("single", 4, "单击"), ("swipe", 5, "滑动"),
]
let gestureActions: [(key: String, value: UInt8, name: String)] = [
    ("xiaoai", 0, "小爱同学"), ("play", 1, "播放/暂停"), ("prev", 2, "上一首"), ("next", 3, "下一首"),
    ("vol+", 4, "音量+"), ("vol-", 5, "音量-"), ("anc", 6, "切换降噪模式"), ("game", 7, "游戏模式"),
    ("none", 8, "无"), ("photo", 9, "拍照"), ("record", 10, "录音/翻译"), ("volume", 11, "调节音量"), ("translate", 12, "同传翻译"),
]
let sceneTable: [(key: String, value: UInt8, name: String)] = [
    ("standard", 1, "标准"), ("music", 2, "音乐"), ("video", 3, "视频"), ("game", 4, "游戏"), ("book", 5, "听书"),
]

func nameOf(_ t: [(key: String, value: UInt8, name: String)], _ v: UInt8) -> String {
    t.first { $0.value == v }?.name ?? "未知(\(v))"
}

final class State {
    var battery: [UInt8] = []
    var firmware: String?
    var mode: UInt8?
    var wearDetect: Bool?
    var hotword: Bool?
    var configs: [UInt16: [UInt8]] = [:]   // configId → value
}

func battText(_ b: UInt8) -> String? {
    if b == 0xFF { return nil }
    return "\(b & 0x7F)%" + ((b & 0x80) != 0 ? "（充电中）" : "")
}

// MARK: - 连接

let serviceUUID = CBUUID(string: "AF00")
let writeUUID = CBUUID(string: "AF07")
let notifyUUID = CBUUID(string: "AF08")

// 状态页要读的配置项
let statusConfigIds: [UInt16] = [0x02, 0x03, 0x04, 0x07, 0x0A, 0x0B, 0x0C, 0x0D, 0x1E, 0x25, 0x29, 0x36, 0x3A, 0x3B, 0x48]

final class Buds: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?
    var buffer: [UInt8] = []
    var seq: UInt8 = 0
    var authed = false
    let state = State()
    let commands: [[UInt8]]   // 认证后要发的 [opcode, payload...] 序列
    let verbose: Bool
    var onReady: (() -> Void)?

    init(commands: [[UInt8]], verbose: Bool) {
        self.commands = commands
        self.verbose = verbose
    }

    func nextSeq() -> UInt8 { defer { seq = seq &+ 1 }; return seq }

    func send(_ m: Msg) {
        let bytes = m.encode()
        if verbose { print(">>", hex(bytes)) }
        guard let p = peripheral, let w = writeChar else { return }
        p.writeValue(Data(bytes), for: w, type: .withoutResponse)
    }

    func request(_ op: Op, _ payload: [UInt8]) {
        send(Msg(type: MsgType.phoneRequest.rawValue, op: op.rawValue, seq: nextSeq(), payload: payload))
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            if c.state == .unauthorized { fputs("没有蓝牙权限\n", stderr); exit(2) }
            if c.state == .poweredOff { fputs("蓝牙没开\n", stderr); exit(2) }
            return
        }
        // 耳机经典蓝牙连着 Mac 时，BLE 也是连着的，直接取出来用
        let list = c.retrieveConnectedPeripherals(withServices: [serviceUUID])
        guard let p = list.first(where: { ($0.name ?? "").range(of: "Buds", options: .caseInsensitive) != nil }) ?? list.first else {
            fputs("没找到已连接的小米耳机（先在 Mac 上连上耳机）\n", stderr)
            exit(2)
        }
        peripheral = p
        p.delegate = self
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        fputs("连接耳机失败: \(error?.localizedDescription ?? "-")\n", stderr)
        exit(2)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            fputs("耳机上没有控制服务 AF00\n", stderr)
            exit(2)
        }
        p.discoverCharacteristics([writeUUID, notifyUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == writeUUID { writeChar = ch }
            if ch.uuid == notifyUUID { p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == notifyUUID, ch.isNotifying else { return }
        var rnd = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &rnd)
        request(.authChallenge, [0x01] + rnd)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        let data = [UInt8](v)
        if verbose { print("<<", hex(data)) }
        // 一个通知里可能带多条报文，也可能一条报文被拆成多个通知，攒到以 EF 结尾再解析
        buffer += data
        if buffer.last == 0xEF {
            let all = buffer
            buffer = []
            for m in Msg.split(all) { handle(m) }
        }
    }

    func handle(_ m: Msg) {
        switch m.op {
        case Op.authChallenge.rawValue:
            if m.type == MsgType.response.rawValue {
                request(.authConfirm, [0x01, 0x00])
            } else if m.payload.count >= 17 {
                let resp = challengeResponse(Array(m.payload[1..<17]))
                send(Msg(type: MsgType.response.rawValue, op: Op.authChallenge.rawValue, seq: m.seq, payload: [0x01] + resp))
            }
        case Op.authConfirm.rawValue:
            if m.type != MsgType.response.rawValue {
                send(Msg(type: MsgType.response.rawValue, op: Op.authConfirm.rawValue, seq: m.seq, payload: [0x01]))
                authed = true
                for c in commands { request(Op(rawValue: c[0])!, Array(c.dropFirst())) }
                // 改完再统一拉一次状态；切模式要一小会儿才生效，有命令时稍等再读
                DispatchQueue.main.asyncAfter(deadline: .now() + (commands.isEmpty ? 0 : 0.8)) { [self] in
                    request(.deviceInfo, [0xFF, 0xFF, 0xFF, 0xFF])
                    request(.runInfo, [0xFF, 0xFF, 0xFF, 0xFF])
                    request(.getConfig, statusConfigIds.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
                    onReady?()
                }
            }
        case Op.deviceInfo.rawValue:
            forEachTLV(m.payload) { idx, v in
                if idx == 0x07 { state.battery = v }
                if idx == 0x01, v.count >= 2 { state.firmware = "\(v[0] >> 4).\(v[0] & 0xF).\(v[1] >> 4).\(v[1] & 0xF)" }
            }
        case Op.runInfo.rawValue:
            forEachTLV(m.payload) { idx, v in
                if idx == 0x09, let b = v.first { state.mode = b }
                if idx == 0x0A, let b = v.first { state.wearDetect = b == 0x00 }
                // 0x05 里嵌着 opcode 08 同格式的 [类型, 值]，类型 2 是语音热词
                if idx == 0x05, v.count >= 3, v[1] == 0x02 { state.hotword = v[2] == 0x01 }
            }
        case Op.reportStatus.rawValue:
            forEachTLV(m.payload) { idx, v in
                if idx == 0x00 { state.battery = v }
                if idx == 0x04, let b = v.first { state.mode = b }
            }
            send(Msg(type: MsgType.response.rawValue, op: Op.reportStatus.rawValue, seq: m.seq, payload: []))
        case Op.getConfig.rawValue:
            parseConfigs(m.payload)
        case Op.notifyConfig.rawValue:
            parseConfigs(m.payload)
            send(Msg(type: MsgType.response.rawValue, op: Op.notifyConfig.rawValue, seq: m.seq, payload: []))
        default:
            break
        }
    }

    // 配置记录：[len][idHi][idLo][value...]，len = value 长度 + 2，多条首尾相接
    func parseConfigs(_ p: [UInt8]) {
        var i = 0
        while i + 2 < p.count {
            let len = Int(p[i])
            let end = min(i + 1 + len, p.count)
            let id = UInt16(p[i + 1]) << 8 | UInt16(p[i + 2])
            state.configs[id] = Array(p[min(i + 3, end)..<end])
            i += len + 1
        }
    }

    // 负载是一串 [len, index, value...]，len 不含自身
    func forEachTLV(_ p: [UInt8], _ body: (UInt8, [UInt8]) -> Void) {
        var i = 0
        while i + 1 < p.count {
            let len = Int(p[i])
            let end = min(i + 1 + len, p.count)
            body(p[i + 1], Array(p[min(i + 2, end)..<end]))
            i += len + 1
        }
    }
}

// MARK: - 命令行

func usage() -> Never {
    print("""
    用法: buds <命令> [参数]   （加 -v 打印收发的原始字节）

    状态
      status                         电量、佩戴、降噪、音效、空间音频、手势等全部状态

    降噪 / 通透
      anc [0-19|light|mid|deep]      降噪；数字是强度档位，0 最轻 19 最深
      anc adaptive                   自适应降噪
      trans [regular|voice|ambient]  通透：标准 / 人声增强 / 环境增强
      off                            关闭降噪和通透
      personal-anc on|off            个性化降噪

    音效
      eq <\(eqTable.map { $0.key }.joined(separator: "|"))>
      spatial on|off                 空间音频
      head on|off                    头部追踪（空间音频的一部分）
      spatial-pref quality|latency   空间音频偏好：音质优先 / 低延迟优先
      scene off|\(sceneTable.map { $0.key }.joined(separator: "|"))   场景渲染
      adaptive-sense on|off          自适应听感
      adaptive-volume on|off         自适应音量

    手势
      gesture <\(gestureTypes.map { $0.key }.joined(separator: "|"))> <left|right|both> <动作>
        动作: \(gestureActions.map { $0.key }.joined(separator: " "))
      cycle <left|right|both> <off,anc,trans 任选组合>   长按在哪几个模式间循环，如 anc,trans

    其他
      find <left|right|both|stop>    让耳机响铃找耳机
      wear-detect on|off             佩戴检测（摘下暂停）
      hotword on|off                 免唤醒语音控制
      auto-answer on|off             自动接听
      dual on|off                    双设备连接
      free-talk off|5|10|15|always   智能免摘：说话时自动通透，停多少秒后恢复
      raw <opcode> <payload...>      调试：直接发十六进制报文
    """)
    exit(1)
}

func onOff(_ s: String?) -> UInt8 {
    switch s {
    case "on", "1", "开": return 1
    case "off", "0", "关": return 0
    default: usage()
    }
}

func lookup(_ t: [(key: String, value: UInt8, name: String)], _ s: String?) -> UInt8 {
    guard let s, let v = t.first(where: { $0.key == s || $0.name == s })?.value else { usage() }
    return v
}

// SET_CONFIG 一条记录
func setConfig(_ id: UInt8, _ value: [UInt8]) -> [UInt8] {
    [Op.setConfig.rawValue, UInt8(value.count + 2), 0x00, id] + value
}

// opcode 08 一条 [类型, 值]
func vendorSet(_ type: UInt8, _ value: UInt8) -> [UInt8] {
    [Op.anc.rawValue, 0x02, type, value]
}

var args = Array(CommandLine.arguments.dropFirst())
let verbose = args.contains("-v")
args.removeAll { $0 == "-v" }
guard let cmd = args.first else { usage() }
let a1 = args.count > 1 ? args[1] : nil
let a2 = args.count > 2 ? args[2] : nil
let a3 = args.count > 3 ? args[3] : nil

// 空间音频是一个位图，改其中一位要先知道其他位，所以这几个命令分两步：先读再写
var spatialChange: ((UInt8) -> UInt8)?

var commands: [[UInt8]] = []
switch cmd {
case "status", "st": break
case "anc", "nc", "降噪":
    commands.append(vendorSet(0x04, 0x01))
    if let o = a1 {
        if o == "adaptive" {
            commands.append(setConfig(0x25, [0x01]))
        } else {
            let named: [String: UInt8] = ["light": 0, "mid": 10, "deep": 19]
            guard let lv = named[o] ?? UInt8(o), lv <= 19 else { usage() }
            commands.append(setConfig(0x25, [0x00]))
            commands.append(setConfig(0x0B, [0x01, lv]))
        }
    }
case "trans", "transparency", "通透":
    commands.append(vendorSet(0x04, 0x02))
    if let o = a1 {
        let map: [String: UInt8] = ["regular": 0, "voice": 1, "ambient": 2]
        guard let v = map[o] else { usage() }
        commands.append(setConfig(0x0B, [0x02, v]))
    }
case "off", "关闭":
    commands.append(vendorSet(0x04, 0x00))
case "personal-anc":
    commands.append(setConfig(0x3B, [onOff(a1)]))
case "eq":
    commands.append(setConfig(0x07, [lookup(eqTable, a1)]))
case "spatial":
    let on = onOff(a1)
    spatialChange = { on == 1 ? $0 | 0x01 : $0 & ~0x01 }
case "head":
    let on = onOff(a1)
    spatialChange = { on == 1 ? $0 | 0x08 : $0 & ~0x08 }
case "spatial-pref":
    let pref: UInt8
    switch a1 {
    case "quality": pref = 0
    case "latency": pref = 1
    default: usage()
    }
    spatialChange = { ($0 & ~0x06) | (pref << 1) }
case "scene":
    if a1 == "off" { commands.append(setConfig(0x36, [0x00])) }
    else { commands.append(setConfig(0x36, [0x01, lookup(sceneTable, a1)])) }
case "adaptive-sense":
    commands.append(setConfig(0x29, [onOff(a1)]))
case "adaptive-volume":
    commands.append(setConfig(0x48, [onOff(a1)]))
case "gesture":
    let type = lookup(gestureTypes, a1)
    let action = lookup(gestureActions, a3)
    switch a2 {
    case "left": commands.append(setConfig(0x02, [type, action, 0xFF]))
    case "right": commands.append(setConfig(0x02, [type, 0xFF, action]))
    case "both": commands.append(setConfig(0x02, [type, action, action]))
    default: usage()
    }
case "cycle":
    guard let list = a2 else { usage() }
    var bits: UInt8 = 0
    for part in list.split(separator: ",") {
        switch part {
        case "off": bits |= 0x01
        case "anc": bits |= 0x02
        case "trans": bits |= 0x04
        default: usage()
        }
    }
    guard bits.nonzeroBitCount >= 2 else { usage() }
    switch a1 {
    case "left": commands.append(setConfig(0x0A, [bits, 0xFF]))
    case "right": commands.append(setConfig(0x0A, [0xFF, bits]))
    case "both": commands.append(setConfig(0x0A, [bits, bits]))
    default: usage()
    }
case "find":
    switch a1 {
    case "left": commands.append(setConfig(0x09, [0x01, 0x01]))
    case "right": commands.append(setConfig(0x09, [0x01, 0x02]))
    case "both", nil: commands.append(setConfig(0x09, [0x01, 0x03]))
    case "stop": commands.append(setConfig(0x09, [0x00, 0x03]))
    default: usage()
    }
case "wear-detect":
    // 注意是反的：0 开、1 关
    commands.append(vendorSet(0x06, onOff(a1) == 1 ? 0x00 : 0x01))
case "hotword":
    commands.append(vendorSet(0x02, onOff(a1)))
case "auto-answer":
    commands.append(setConfig(0x03, [onOff(a1)]))
case "dual":
    commands.append(setConfig(0x04, [onOff(a1)]))
case "free-talk":
    switch a1 {
    case "off": commands.append(setConfig(0x0D, [0x00, 0x00]))
    case "5", "10", "15": commands.append(setConfig(0x0D, [0x01, UInt8(a1!)!]))
    case "always": commands.append(setConfig(0x0D, [0x01, 0xFF]))
    default: usage()
    }
case "raw":
    let bytes = args.dropFirst().compactMap { UInt8($0, radix: 16) }
    guard bytes.count == args.count - 1, !bytes.isEmpty, Op(rawValue: bytes[0]) != nil else { usage() }
    commands.append(bytes)
case "help", "-h", "--help":
    usage()
default:
    usage()
}

let buds = Buds(commands: commands, verbose: verbose)
buds.start()

func onOffText(_ v: [UInt8]?) -> String? {
    guard let b = v?.first else { return nil }
    return b == 1 ? "开" : "关"
}

func finish() {
    let s = buds.state
    let c = s.configs
    var lines: [String] = ["耳机: \(buds.peripheral?.name ?? "-")" + (s.firmware.map { "（固件 \($0)）" } ?? "")]

    if s.battery.count >= 3 {
        let parts = zip(["左耳", "右耳", "充电盒"], s.battery.prefix(3)).compactMap { k, b in battText(b).map { "\(k) \($0)" } }
        lines.append("电量: " + parts.joined(separator: "  "))
    }
    if let w = c[0x0C]?.first {
        let l = w & 0x08 != 0 ? "戴着" : (w & 0x02 != 0 ? "在盒里" : "没戴")
        let r = w & 0x04 != 0 ? "戴着" : (w & 0x01 != 0 ? "在盒里" : "没戴")
        lines.append("佩戴: 左耳\(l)  右耳\(r)")
    }

    // 降噪：模式以运行信息为准，档位看 0x0B
    let mode = s.mode ?? c[0x0B]?.first
    if let m = mode {
        var line = "模式: \(modeNames[m] ?? "未知(\(m))")"
        let lv = c[0x0B]
        if m == 1 {
            if c[0x25]?.first == 1 { line += "（自适应）" }
            else if let lv, lv.count >= 2, lv[0] == 1 { line += "（强度 \(lv[1])/19）" }
        } else if m == 2, let lv, lv.count >= 2, lv[0] == 2 {
            line += "（\(transLevelNames[lv[1]] ?? "\(lv[1])")）"
        }
        lines.append(line)
    }
    if let v = onOffText(c[0x25]) { lines.append("自适应降噪: \(v)") }
    if let v = onOffText(c[0x3B]) { lines.append("个性化降噪: \(v)") }
    if let cyc = c[0x0A], cyc.count >= 2 {
        func names(_ b: UInt8) -> String {
            [(0x02, "降噪"), (0x04, "通透"), (0x01, "关闭")].filter { b & UInt8($0.0) != 0 }.map { $0.1 }.joined(separator: "↔")
        }
        lines.append("长按循环: 左耳 \(names(cyc[0]))  右耳 \(names(cyc[1]))")
    }

    if let e = c[0x07]?.first { lines.append("音效: \(nameOf(eqTable, e))") }
    if let sp = c[0x1E]?.first {
        let pref = (sp >> 1) & 0x03 == 0 ? "音质优先" : "低延迟优先"
        lines.append("空间音频: \(sp & 0x01 != 0 ? "开" : "关")  头部追踪: \(sp & 0x08 != 0 ? "开" : "关")  偏好: \(pref)")
    }
    if let sc = c[0x36] {
        lines.append("场景渲染: " + (sc.first == 1 && sc.count >= 2 ? nameOf(sceneTable, sc[1]) : "关"))
    }
    if let v = onOffText(c[0x29]) { lines.append("自适应听感: \(v)") }
    if let v = onOffText(c[0x48]) { lines.append("自适应音量: \(v)") }

    if let g = c[0x02] {
        var i = 0
        var parts: [String] = []
        while i + 2 < g.count {
            let t = nameOf(gestureTypes, g[i])
            let l = nameOf(gestureActions, g[i + 1]), r = nameOf(gestureActions, g[i + 2])
            parts.append(l == r ? "\(t)=\(l)" : "\(t)=左\(l)/右\(r)")
            i += 3
        }
        lines.append("手势: " + parts.joined(separator: "  "))
    }

    if let v = s.wearDetect { lines.append("佩戴检测: \(v ? "开" : "关")") }
    if let v = s.hotword { lines.append("免唤醒语音: \(v ? "开" : "关")") }
    if let v = onOffText(c[0x03]) { lines.append("自动接听: \(v)") }
    if let v = onOffText(c[0x04]) { lines.append("双设备连接: \(v)") }
    if let ft = c[0x0D], ft.count >= 2 {
        lines.append("智能免摘: " + (ft[0] == 0 ? "关" : (ft[1] == 0xFF ? "开（不自动恢复）" : "开（\(ft[1]) 秒后恢复）")))
    }
    print(lines.joined(separator: "\n"))
    exit(0)
}

buds.onReady = {
    if let change = spatialChange {
        // 先等状态里的 0x1E 回来，算出新位图再写 0x1D，然后重读一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let cur = buds.state.configs[0x1E]?.first else {
                fputs("读不到空间音频状态\n", stderr)
                exit(3)
            }
            buds.request(.setConfig, [0x03, 0x00, 0x1D, change(cur)])
            buds.request(.getConfig, [0x00, 0x1E])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { finish() }
        }
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    if !buds.authed {
        fputs("认证超时：耳机没有回应\n", stderr)
        exit(3)
    }
}
RunLoop.main.run()
