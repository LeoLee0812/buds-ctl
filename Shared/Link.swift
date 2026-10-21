// BudsLink：通过 BLE 连上耳机、完成认证、收发报文，并把回包解析进 BudsState
import CoreBluetooth
import Foundation

let serviceUUID = CBUUID(string: "AF00")
let writeUUID = CBUUID(string: "AF07")
let notifyUUID = CBUUID(string: "AF08")

// 状态页要读的配置项
let statusConfigIds: [UInt16] = [0x02, 0x03, 0x04, 0x07, 0x0A, 0x0B, 0x0C, 0x0D, 0x1E, 0x25, 0x29, 0x36, 0x3A, 0x3B, 0x48]

// SET_CONFIG 一条记录：[opcode, len, idHi, idLo, value...]
func setConfig(_ id: UInt8, _ value: [UInt8]) -> [UInt8] {
    [Op.setConfig.rawValue, UInt8(value.count + 2), 0x00, id] + value
}

// opcode 08 一条 [类型, 值]
func vendorSet(_ type: UInt8, _ value: UInt8) -> [UInt8] {
    [Op.anc.rawValue, 0x02, type, value]
}

final class BudsLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Phase { case idle, searching, connecting, ready, notFound, bluetoothOff, unauthorized }

    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?
    var buffer: [UInt8] = []
    var seq: UInt8 = 0
    var state = BudsState()
    var phase: Phase = .idle { didSet { onPhase?(phase) } }
    let verbose: Bool

    var onAuthed: (() -> Void)?
    var onChange: (() -> Void)?
    var onPhase: ((Phase) -> Void)?

    init(verbose: Bool = false) {
        self.verbose = verbose
    }

    var authed: Bool { phase == .ready }
    var name: String? { peripheral?.name }

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            connect()
        }
    }

    func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
    }

    // MARK: 发送

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

    // 发一条 [opcode, payload...]
    func command(_ c: [UInt8]) {
        guard let op = Op(rawValue: c[0]) else { return }
        request(op, Array(c.dropFirst()))
    }

    func requestStatus() {
        request(.deviceInfo, [0xFF, 0xFF, 0xFF, 0xFF])
        request(.runInfo, [0xFF, 0xFF, 0xFF, 0xFF])
        request(.getConfig, statusConfigIds.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }

    // MARK: BLE

    func connect() {
        guard central.state == .poweredOn else { return }
        // 耳机经典蓝牙连着 Mac 时，BLE 也是连着的，直接取出来用
        let list = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
        if let p = list.first(where: { isBuds($0.name) }) ?? list.first {
            attach(p)
            return
        }
        // BLE 断过一次后系统不会自己重连，要扫描它的广播再连
        phase = .searching
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.phase == .searching else { return }
            self.central.stopScan()
            self.phase = .notFound
        }
    }

    func isBuds(_ name: String?) -> Bool {
        (name ?? "").range(of: "Buds", options: .caseInsensitive) != nil
    }

    func attach(_ p: CBPeripheral) {
        phase = .connecting
        peripheral = p
        p.delegate = self
        central.connect(p)
        // 耳机在盒里或走远了，connect 会一直挂着，超时就放弃，等下一轮重试
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.phase == .connecting else { return }
            self.central.cancelPeripheralConnection(p)
            self.phase = .notFound
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard phase == .searching else { return }
        let adName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard isBuds(p.name) || isBuds(adName) else { return }
        c.stopScan()
        attach(p)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: connect()
        case .unauthorized: phase = .unauthorized
        case .poweredOff: phase = .bluetoothOff
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        phase = .notFound
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        writeChar = nil
        buffer = []
        phase = .notFound
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            phase = .notFound
            return
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

    // MARK: 解析

    func handle(_ m: Msg) {
        switch m.op {
        case Op.authChallenge.rawValue:
            if m.type == MsgType.response.rawValue {
                request(.authConfirm, [0x01, 0x00])
            } else if m.payload.count >= 17 {
                let resp = challengeResponse(Array(m.payload[1..<17]))
                send(Msg(type: MsgType.response.rawValue, op: Op.authChallenge.rawValue, seq: m.seq, payload: [0x01] + resp))
            }
            return
        case Op.authConfirm.rawValue:
            if m.type != MsgType.response.rawValue {
                send(Msg(type: MsgType.response.rawValue, op: Op.authConfirm.rawValue, seq: m.seq, payload: [0x01]))
                phase = .ready
                onAuthed?()
            }
            return
        case Op.deviceInfo.rawValue:
            forEachTLV(m.payload) { idx, v in
                if idx == 0x07 { state.battery = v }
                if idx == 0x01, v.count >= 2 { state.firmware = "\(v[0] >> 4).\(v[0] & 0xF).\(v[1] >> 4).\(v[1] & 0xF)" }
            }
        case Op.runInfo.rawValue:
            forEachTLV(m.payload) { idx, v in
                if idx == 0x09, let b = v.first { state.mode = b }
                if idx == 0x0A, let b = v.first { state.wearDetect = b == 0x00 }
                // 0x05 里嵌着 opcode 08 同格式的 [长度, 类型, 值]，类型 2 是语音热词
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
            return
        }
        onChange?()
    }

    // 配置记录：[len][idHi][idLo][value...]，len = value 长度 + 2，多条首尾相接
    func parseConfigs(_ p: [UInt8]) {
        var i = 0
        while i + 2 < p.count {
            let len = Int(p[i])
            let end = min(i + 1 + len, p.count)
            let id = UInt16(p[i + 1]) << 8 | UInt16(p[i + 2])
            state.configs[id] = Array(p[min(i + 3, end)..<end])
            // 0x0B 带着当前模式，耳机长按切模式时会通过 F4 推过来
            if id == 0x0B, let m = state.configs[id]?.first { state.mode = m }
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
