// Рисует иконку приложения и собирает набор для .icns.
//
//   make icon            (или: swift scripts/make-icon.swift [превью.png])
//
// Рисунок — сам таймлайн дня, как в главном окне, сведённый к главному.
//
// Стиль — минимализм на белом (просьба пользователя 28.09.2026): белая
// подложка и три знака таймлайна — два письма, встреча и линия «сейчас».
// Файла Icon Composer (`.icon`) без Xcode не собрать, поэтому рисунок
// строится здесь, кодом: его легко поправить и пересобрать.

import AppKit
import CoreImage
import SwiftUI

let sizes = [16, 32, 128, 256, 512]
let iconset = URL(fileURLWithPath: "build/Trudaybook.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

/// Скругление «непрерывное», как у системных иконок, а не дугой окружности.
func shape(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func bitmap(_ side: Int) -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Сетка 1024×1024, y растёт вверх (как в Core Graphics). Подложка — по сетке
// системных иконок: 824×824 с отступом 100.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 186

/// Подложка без стекла: синий градиент и пятна света. Её же, размытую,
/// видно сквозь стеклянные элементы.
func drawBackdrop(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(shape(plate, plateRadius))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x69A6FF)), (0.5, color(0x2F62E6)), (1, color(0x1B36A8))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Пятна света: голубое сверху слева, сиреневое снизу справа —
    // стеклу есть что преломлять.
    let spots: [(CGPoint, CGFloat, CGColor)] = [
        (CGPoint(x: 250, y: 860), 460, color(0x9FE8FF, 0.75)),
        (CGPoint(x: 880, y: 180), 420, color(0x8C6BFF, 0.55)),
        (CGPoint(x: 820, y: 820), 300, color(0x6FD6FF, 0.35)),
    ]
    for (center, radius, tint) in spots {
        ctx.drawRadialGradient(gradient([(0, tint), (1, tint.copy(alpha: 0)!)]),
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    ctx.restoreGState()
}

/// Кромка стекла: яркая сверху слева, гаснет к середине, снова светлеет
/// снизу справа — так свет проходит сквозь толщу стекла.
func rim(_ ctx: CGContext, _ path: CGPath, width: CGFloat, strength: CGFloat = 1) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(path)
    ctx.setLineWidth(width * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, white(0.95 * strength)), (0.32, white(0.22 * strength)),
                  (0.68, white(0.08 * strength)), (1, white(0.55 * strength))]),
        start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    ctx.restoreGState()
}

struct Glass {
    var path: CGPath
    /// Цвет стекла сверху и снизу; `nil` — прозрачное, чуть матовое.
    /// Цветное стекло — плотное: полупрозрачный янтарь над синим
    /// выходил бурым.
    var tint: (top: CGColor, bottom: CGColor)?
    var shadow = true
}

/// Стеклянный элемент: тень, линза (размытая и увеличенная подложка),
/// матовость или цвет, блеск сверху, кромка.
func drawGlass(_ ctx: CGContext, _ glass: Glass, lens: CGImage, small: Bool) {
    let box = glass.path.boundingBox
    if glass.shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: small ? -8 : -14), blur: small ? 14 : 26,
                      color: color(0x0A1A5C, 0.45))
        ctx.addPath(glass.path)
        ctx.setFillColor(color(0x2F62E6))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(glass.path)
    ctx.clip()
    // Линза: подложка сквозь стекло крупнее на десятую — будто сквозь каплю.
    let zoom: CGFloat = 1.1
    let center = CGPoint(x: box.midX, y: box.midY)
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: zoom, y: zoom)
    ctx.translateBy(x: -center.x, y: -center.y)
    ctx.draw(lens, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(glass.path)
    ctx.clip()
    if let tint = glass.tint {
        ctx.drawLinearGradient(gradient([(0, tint.top), (1, tint.bottom)]),
                               start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    } else {
        ctx.setFillColor(white(small ? 0.62 : 0.3))
        ctx.fill(box)
    }
    // Блеск: верхняя треть светлее; на цветном — слабее, иначе цвет белеет.
    let sheen: CGFloat = glass.tint == nil ? 0.42 : 0.22
    ctx.drawLinearGradient(gradient([(0, white(sheen)), (0.45, white(0.04)), (1, white(0))]),
                           start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    // Нижний край чуть темнее — у стекла есть толщина.
    ctx.drawLinearGradient(gradient([(0, color(0x0A1A5C, 0)), (0.8, color(0x0A1A5C, 0)), (1, color(0x0A1A5C, 0.16))]),
                           start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
    rim(ctx, glass.path, width: small ? 3 : 4)
}

/// Светящаяся точка «не прочитано». На мелких размерах карточки плотнее,
/// и белая точка на них теряется — там она насыщенно-синяя.
func drawDot(_ ctx: CGContext, center: CGPoint, radius: CGFloat, small: Bool) {
    if small {
        ctx.setFillColor(color(0x0A6CFF))
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return
    }
    let disc = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: radius * 1.6, color: color(0x7FD8FF, 0.9))
    ctx.setFillColor(white(1))
    ctx.fillEllipse(in: disc)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: disc)
    ctx.clip()
    ctx.drawRadialGradient(gradient([(0, white(1)), (0.55, color(0xCDEFFF)), (1, color(0x5CC8FF))]),
                           startCenter: CGPoint(x: center.x - radius * 0.3, y: center.y + radius * 0.3), startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
    ctx.restoreGState()
}

/// Плоский элемент на белом: цвет с лёгким переходом сверху вниз и тонкий
/// блик по верхнему краю — чуть объёма без стекла и теней-луж.
func drawTile(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor, small: Bool) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: small ? -3 : -6), blur: small ? 6 : 14, color: color(0x1B2A55, 0.16))
    ctx.addPath(path)
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, top), (1, bottom)]),
                           start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
    rim(ctx, path, width: small ? 2 : 3, strength: 0.45)
}

func draw(_ ctx: CGContext, small: Bool) {
    // Подложка — белая, с едва заметным переходом к серому внизу: на белом
    // фоне Finder иконка не растворяется, на тёмном Dock — светится.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, 0.22))
    ctx.addPath(shape(plate, plateRadius))
    ctx.setFillColor(white(1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape(plate, plateRadius))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xFFFFFF)), (1, color(0xEEF1F6))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Всего три знака таймлайна: два письма, встреча и линия «сейчас».
    let blueTop = color(0x5B9BFF), blueBottom = color(0x2F6BEA)
    let letterWidth: CGFloat = small ? 110 : 96
    for x in small ? [CGFloat(206), 346] : [CGFloat(214), 338] {
        let rect = CGRect(x: x, y: 520, width: letterWidth, height: 290)
        drawTile(ctx, shape(rect, letterWidth / 2), top: blueTop, bottom: blueBottom, small: small)
    }
    let meeting = CGRect(x: 548, y: 250, width: 262, height: 196)
    drawTile(ctx, shape(meeting, 58), top: color(0xFFC766), bottom: color(0xFF9227), small: small)

    // Линия «сейчас» с каплей — одна фигура, красная.
    let nowX: CGFloat = 498
    let line = shape(CGRect(x: nowX - (small ? 16 : 12), y: 188, width: small ? 32 : 24, height: 640), small ? 16 : 12)
        .union(shape(CGRect(x: nowX - 56, y: 800, width: 112, height: 64), 32))
    drawTile(ctx, line, top: color(0xFF5A4F), bottom: color(0xE8261B), small: small)
    ctx.restoreGState()

    // Тонкая кромка — край белой иконки на белом фоне.
    ctx.saveGState()
    ctx.addPath(shape(plate.insetBy(dx: 1, dy: 1), plateRadius))
    ctx.setStrokeColor(color(0x000000, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int) -> Data? {
    let ctx = bitmap(size)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    // На 16 и 32 точках мелочь сливается в кашу — рисуем проще и плотнее.
    draw(ctx, small: size <= 64)
    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = render(size: size), let retina = render(size: size * 2) else {
        print("не удалось нарисовать \(size)")
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try retina.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// Превью для проверки глазами: большая иконка и мелкие рядом.
if CommandLine.arguments.count > 1, let big = render(size: 1024) {
    try big.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    for size in [32, 64] {
        if let small = render(size: size) {
            try small.write(to: URL(fileURLWithPath: CommandLine.arguments[1].replacingOccurrences(of: ".png", with: "-\(size).png")))
        }
    }
}

print("иконки нарисованы в \(iconset.path)")
