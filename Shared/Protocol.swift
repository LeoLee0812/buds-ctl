// 小米耳机 MMA 协议：认证、帧编解码、取值表（命令行和菜单栏 App 共用）
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

struct BudsState {
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

