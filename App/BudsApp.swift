// 菜单栏 App：点菜单栏的耳机图标，弹出面板控制小米耳机
import SwiftUI

// 宣纸暖色底、深棕字、天蓝点缀
extension Color {
    static let paper = Color(red: 0.965, green: 0.937, blue: 0.886)
    static let paperDeep = Color(red: 0.925, green: 0.890, blue: 0.827)
    static let ink = Color(red: 0.282, green: 0.204, blue: 0.149)
    static let inkSoft = Color(red: 0.282, green: 0.204, blue: 0.149).opacity(0.55)
    static let sky = Color(red: 0.294, green: 0.639, blue: 0.890)
}

@main
struct BudsApp: App {
    @StateObject private var model = BudsModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            if let b = model.lowestBattery, model.phase == .ready {
                Label("\(b)%", systemImage: "earbuds").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "earbuds")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @EnvironmentObject var model: BudsModel
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.phase == .ready {
                ModeSwitcher()
                modeDetail
                Divider().overlay(Color.paperDeep)
                soundSection
                Divider().overlay(Color.paperDeep)
                DisclosureGroup(isExpanded: $showMore) {
                    MoreView().padding(.top, 8)
                } label: {
                    Text("更多设置").font(.system(size: 13, weight: .medium))
                }
            } else {
                statusHint
            }
            Divider().overlay(Color.paperDeep)
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(Color.paper)
        .foregroundStyle(Color.ink)
        .tint(.sky)
        .toggleStyle(.switch)
        .controlSize(.small)
        // 系统是深色模式时控件会变成白字，和宣纸底冲突，固定用浅色
        .environment(\.colorScheme, .light)
        .onAppear { model.refresh() }
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "earbuds")
                .font(.system(size: 22))
                .foregroundStyle(Color.sky)
            Text(model.name.replacingOccurrences(of: "Xiaomi ", with: ""))
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if model.phase == .ready {
                let b = model.battery
                HStack(spacing: 10) {
                    BatteryChip(label: "L", value: b.left)
                    BatteryChip(label: "R", value: b.right)
                    if b.box != nil { BatteryChip(label: "盒", value: b.box) }
                }
            }
        }
    }

    @ViewBuilder var modeDetail: some View {
        switch model.mode {
        case 1:
            VStack(alignment: .leading, spacing: 8) {
                if model.has(0x25) { Toggle("自适应降噪", isOn: Binding(get: { model.adaptiveAnc }, set: { model.setAdaptiveAnc($0) })) }
                if !model.adaptiveAnc {
                    AncSlider()
                }
            }
        case 2:
            Picker("", selection: Binding(get: { model.transLevel }, set: { model.setTransLevel($0) })) {
                Text("标准").tag(UInt8(0))
                Text("人声增强").tag(UInt8(1))
                Text("环境增强").tag(UInt8(2))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        default:
            EmptyView()
        }
    }

    var soundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.has(0x07) {
            Picker("音效", selection: Binding(get: { model.eq }, set: { model.setEq($0) })) {
                ForEach(eqTable.filter { $0.key != "custom" }, id: \.value) { Text($0.name).tag($0.value) }
                if model.eq == 0x0A { Text("自定义").tag(UInt8(0x0A)) }
            }
            }
            let sp = model.spatialBits
            if model.has(0x1E) {
            Toggle("空间音频", isOn: Binding(get: { sp & 0x01 != 0 }, set: { on in model.setSpatial { on ? $0 | 0x01 : $0 & ~0x01 } }))
            if sp & 0x01 != 0 {
                Toggle("头部追踪", isOn: Binding(get: { sp & 0x08 != 0 }, set: { on in model.setSpatial { on ? $0 | 0x08 : $0 & ~0x08 } }))
                Picker("偏好", selection: Binding(get: { (sp >> 1) & 0x03 }, set: { v in model.setSpatial { ($0 & ~0x06) | (v << 1) } })) {
                    Text("音质优先").tag(UInt8(0))
                    Text("低延迟优先").tag(UInt8(1))
                }
                .pickerStyle(.segmented)
            }
            }
            if model.has(0x36) {
            Picker("场景渲染", selection: Binding(get: { model.scene }, set: { model.setScene($0) })) {
                Text("关").tag(UInt8(0))
                ForEach(sceneTable, id: \.value) { Text($0.name).tag($0.value) }
            }
            }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder var statusHint: some View {
        let text: String = switch model.phase {
        case .bluetoothOff: "蓝牙没开"
        case .unauthorized: "没有蓝牙权限：系统设置 → 隐私与安全性 → 蓝牙，打开本 App"
        case .connecting, .searching: "正在连接耳机…"
        default: "耳机没连上这台 Mac"
        }
        HStack {
            Text(text).font(.system(size: 13)).foregroundStyle(Color.inkSoft)
            Spacer()
            if model.phase != .connecting && model.phase != .searching {
                Button("重试") { model.refresh() }
            }
        }
    }

    var footer: some View {
        HStack {
            Toggle("开机自启", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .font(.system(size: 12))
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSoft)
        }
    }
}

struct BatteryChip: View {
    let label: String
    let value: UInt8?

    var body: some View {
        if let v = value {
            let pct = Int(v & 0x7F)
            HStack(spacing: 3) {
                Text(label).foregroundStyle(Color.inkSoft)
                Text("\(pct)%")
                if v & 0x80 != 0 { Image(systemName: "bolt.fill").foregroundStyle(Color.sky) }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(pct <= 15 ? Color.red : Color.ink)
        }
    }
}

// 降噪 / 关闭 / 通透 三段大按钮
struct ModeSwitcher: View {
    @EnvironmentObject var model: BudsModel

    var body: some View {
        HStack(spacing: 8) {
            button(1, "降噪", "person.wave.2.fill")
            button(0, "关闭", "circle.slash")
            button(2, "通透", "ear.and.waveform")
        }
    }

    func button(_ m: UInt8, _ title: String, _ icon: String) -> some View {
        let on = model.mode == m
        return Button {
            model.setMode(m)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.sky : Color.paperDeep))
            .foregroundStyle(on ? Color.white : Color.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// 降噪强度 0~19，松手才发给耳机
struct AncSlider: View {
    @EnvironmentObject var model: BudsModel
    @State private var value: Double = 19
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Text("轻").font(.system(size: 12)).foregroundStyle(Color.inkSoft)
            Slider(value: $value, in: 0...19, step: 1) { e in
                editing = e
                if !e { model.setAncLevel(value) }
            }
            Text("深").font(.system(size: 12)).foregroundStyle(Color.inkSoft)
        }
        .onAppear { value = model.ancLevel }
        .onChange(of: model.ancLevel) { _, v in if !editing { value = v } }
    }
}

struct MoreView: View {
    @EnvironmentObject var model: BudsModel
    @State private var finding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.has(0x3B) { Toggle("个性化降噪", isOn: Binding(get: { model.personalAnc }, set: { model.setSwitch(0x3B, $0) })) }
            if model.has(0x29) { Toggle("自适应听感", isOn: Binding(get: { model.adaptiveSense }, set: { model.setSwitch(0x29, $0) })) }
            if model.has(0x48) { Toggle("自适应音量", isOn: Binding(get: { model.adaptiveVolume }, set: { model.setSwitch(0x48, $0) })) }
            if model.state.wearDetect != nil { Toggle("佩戴检测", isOn: Binding(get: { model.wearDetect }, set: { model.setWearDetect($0) })) }
            if model.state.hotword != nil { Toggle("免唤醒语音", isOn: Binding(get: { model.hotword }, set: { model.setHotword($0) })) }
            if model.has(0x03) { Toggle("自动接听", isOn: Binding(get: { model.autoAnswer }, set: { model.setSwitch(0x03, $0) })) }
            if model.has(0x04) { Toggle("双设备连接", isOn: Binding(get: { model.dual }, set: { model.setSwitch(0x04, $0) })) }
            if model.has(0x0D) {
            Picker("智能免摘", selection: Binding(get: { model.freeTalk }, set: { model.setFreeTalk($0) })) {
                Text("关").tag(UInt8(0))
                Text("5 秒后恢复").tag(UInt8(5))
                Text("10 秒后恢复").tag(UInt8(10))
                Text("15 秒后恢复").tag(UInt8(15))
                Text("不自动恢复").tag(UInt8(0xFF))
            }
            }

            Divider().overlay(Color.paperDeep)
            ForEach(gestureTypes, id: \.value) { t in
                if let g = model.gesture(t.value) {
                    Picker(t.name, selection: Binding(get: { g.left }, set: { model.setGesture(t.value, $0) })) {
                        ForEach(gestureActions, id: \.value) { Text($0.name).tag($0.value) }
                    }
                }
            }

            Divider().overlay(Color.paperDeep)
            Button {
                finding.toggle()
                model.find(finding)
            } label: {
                Label(finding ? "停止响铃" : "查找耳机（会响铃）", systemImage: finding ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            if let fw = model.state.firmware {
                Text("固件 \(fw)").font(.system(size: 11)).foregroundStyle(Color.inkSoft)
            }
        }
        .font(.system(size: 13))
    }
}
