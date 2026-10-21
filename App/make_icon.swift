// 生成 App 图标：宣纸色圆角方块 + 两只深棕色耳机 + 天蓝小圆点（全部手绘路径，不用系统图标）
// 用法：swift App/make_icon.swift 输出.png
import AppKit

let size: CGFloat = 1024
let paper = NSColor(red: 0.965, green: 0.937, blue: 0.886, alpha: 1)
let ink = NSColor(red: 0.282, green: 0.204, blue: 0.149, alpha: 1)
let sky = NSColor(red: 0.294, green: 0.639, blue: 0.890, alpha: 1)

// 一只耳机：圆形耳塞头 + 向下的耳机柄，mirror 为 true 时左右翻转
func earbud(centerX: CGFloat, mirror: Bool) {
    let s: CGFloat = mirror ? -1 : 1
    let head = NSBezierPath(ovalIn: NSRect(x: centerX - 125, y: 470, width: 250, height: 250))
    ink.setFill()
    head.fill()

    // 耳塞头上的出音口
    paper.setFill()
    NSBezierPath(ovalIn: NSRect(x: centerX - 55 * s - 32, y: 570, width: 64, height: 84)).fill()

    // 耳机柄：从耳塞头偏外侧往下伸出
    let stemX = centerX + 40 * s
    let stem = NSBezierPath(roundedRect: NSRect(x: stemX - 52, y: 215, width: 104, height: 330), xRadius: 52, yRadius: 52)
    ink.setFill()
    stem.fill()
}

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
paper.setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
earbud(centerX: 365, mirror: false)
earbud(centerX: 659, mirror: true)
sky.setFill()
NSBezierPath(ovalIn: NSRect(x: 740, y: 740, width: 96, height: 96)).fill()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
