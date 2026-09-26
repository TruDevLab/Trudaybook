// Рисует иконку приложения и собирает набор для .icns.
//
//   make icon            (или: swift scripts/make-icon.swift [превью.png])
//
// Рисунок — сам таймлайн дня, как в главном окне: узкие карточки писем
// сверху, блоки встреч под ними, шкала часов и красная линия «сейчас».
// Картинка строится кодом, чтобы её было легко поправить и пересобрать.

import AppKit
import Foundation

let sizes = [16, 32, 128, 256, 512]
let iconset = URL(fileURLWithPath: "build/Trudaybook.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

/// Всё рисуется в сетке 1024×1024 (координаты AppKit: y растёт вверх)
/// и масштабируется под нужный размер.
func draw(small: Bool) {
    // Подложка по сетке системных иконок macOS: 824×824 с отступом 100.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x1D3A8F).setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0x3B6FE0), color(0x2346B0), color(0x172C74)],
               atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)?.draw(in: platePath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()

    // Лёгкий блик сверху — объём, как у системных иконок.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])?
        .draw(in: CGRect(x: 100, y: 620, width: 824, height: 304), angle: -90)

    // Разделитель дорожек: письма сверху, встречи снизу.
    if !small {
        color(0xFFFFFF, 0.18).setFill()
        for x in stride(from: CGFloat(190), to: 840, by: 34) {
            rounded(x, 528, 18, 5, 2.5).fill()
        }
    }

    // Письма — узкие вертикальные карточки, часть собрана в пачку.
    let cards: [(x: CGFloat, alpha: CGFloat, unread: Bool)] = small
        ? [(200, 1, true), (300, 0.8, false), (630, 1, true)]
        : [(196, 1, true), (276, 0.9, false), (356, 0.72, false), (596, 1, true), (676, 0.6, false), (756, 0.85, false)]
    let cardWidth: CGFloat = small ? 80 : 64
    for card in cards {
        color(0xFFFFFF, card.alpha).setFill()
        rounded(card.x, 566, cardWidth, 246, small ? 26 : 22).fill()
        if !small {
            // Строки текста на карточке — повёрнутые подписи, как в окне.
            color(0x2346B0, 0.28).setFill()
            rounded(card.x + 20, 594, 9, 150, 4.5).fill()
            rounded(card.x + 36, 594, 9, 110, 4.5).fill()
        }
        if card.unread {
            color(0x0A84FF).setFill()
            let dot: CGFloat = small ? 30 : 22
            NSBezierPath(ovalIn: CGRect(x: card.x + (cardWidth - dot) / 2, y: 812 - 22 - dot, width: dot, height: dot)).fill()
        }
    }

    // Встречи — блоки по длительности.
    let meeting = rounded(468, 318, 300, 176, 34)
    NSGradient(colors: [color(0xFFC766), color(0xFF9F2E)])?.draw(in: meeting, angle: -90)
    color(0xFFFFFF, 0.92).setFill()
    rounded(196, 352, 196, 142, 30).fill()
    if !small {
        color(0x2346B0, 0.3).setFill()
        rounded(222, 448, 120, 16, 8).fill()
        rounded(222, 418, 80, 14, 7).fill()
        color(0xFFFFFF, 0.85).setFill()
        rounded(496, 448, 150, 16, 8).fill()
        rounded(496, 418, 100, 14, 7).fill()
        // Полоса слева у блока встречи — цвет календаря, по форме блока.
        NSGraphicsContext.saveGraphicsState()
        meeting.addClip()
        color(0xE0701A).setFill()
        NSBezierPath(rect: CGRect(x: 468, y: 318, width: 14, height: 176)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Шкала часов.
    color(0xFFFFFF, 0.45).setFill()
    rounded(170, 262, 684, 6, 3).fill()
    if !small {
        for x in stride(from: CGFloat(196), through: 830, by: 106) {
            rounded(x - 3, 226, 6, 36, 3).fill()
        }
    }

    // Линия «сейчас» с каплей сверху — главный знак окна.
    let nowX: CGFloat = 452
    color(0xFF3B30).setFill()
    rounded(nowX - 7, 200, 14, 640, 7).fill()
    rounded(nowX - 46, 822, 92, 52, 26).fill()

    NSGraphicsContext.restoreGraphicsState()

    // Тонкая светлая кромка — иконка не сливается с тёмным Dock.
    color(0xFFFFFF, 0.14).setStroke()
    let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    edge.lineWidth = 3
    edge.stroke()
}

func render(size: Int) -> Data? {
    // Растр с точными пикселями, а не `NSImage.lockFocus`: тот рисует
    // в масштабе экрана, и файлы выходили бы вдвое крупнее своих имён.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.setShouldAntialias(true)
    graphics.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    // На 16 и 32 точках мелочь сливается в кашу — рисуем проще.
    draw(small: size <= 64)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
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
