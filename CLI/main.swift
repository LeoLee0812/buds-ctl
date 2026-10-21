// buds：在 Mac 上控制小米耳机的命令行工具
import Foundation

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

let buds = BudsLink(verbose: verbose)
buds.onPhase = { phase in
    switch phase {
    case .notFound: fputs("没找到已连接的小米耳机（先在 Mac 上连上耳机）\n", stderr); exit(2)
    case .bluetoothOff: fputs("蓝牙没开\n", stderr); exit(2)
    case .unauthorized: fputs("没有蓝牙权限\n", stderr); exit(2)
    default: break
    }
}
buds.start()

func onOffText(_ v: [UInt8]?) -> String? {
    guard let b = v?.first else { return nil }
    return b == 1 ? "开" : "关"
}

func finish() {
    let s = buds.state
    let c = s.configs
    var lines: [String] = ["耳机: \(buds.name ?? "-")" + (s.firmware.map { "（固件 \($0)）" } ?? "")]

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

func afterStatus() {
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

buds.onAuthed = {
    for c in commands { buds.command(c) }
    // 切模式要一小会儿才生效，有命令时稍等再读状态
    DispatchQueue.main.asyncAfter(deadline: .now() + (commands.isEmpty ? 0 : 0.8)) {
        buds.requestStatus()
        afterStatus()
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    if !buds.authed {
        fputs("认证超时：耳机没有回应\n", stderr)
        exit(3)
    }
}
RunLoop.main.run()
