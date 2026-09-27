import AppKit
import ImageIO
import SwiftUI
import TrudaybookCore

/// Фон главного окна: системный, «сияние» из Trunook, свой цвет, градиент
/// или своя картинка. Под стеклянными панелями (Liquid Glass) фон и есть
/// то, что делает окно «своим».
enum AppBackground: String, CaseIterable, Identifiable {
    case system, sky, aurora, color, gradient, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Системный")
        case .sky: String(localized: "Небо: время суток и погода")
        case .aurora: String(localized: "Сияние, как в Trunook")
        case .color: String(localized: "Цвет")
        case .gradient: String(localized: "Градиент")
        case .image: String(localized: "Картинка")
        }
    }

    /// Для переключателя: шесть длинных подписей в ряд не помещаются.
    var shortTitle: String {
        switch self {
        case .system: String(localized: "Система")
        case .sky: String(localized: "Небо")
        case .aurora: String(localized: "Сияние")
        case .color: String(localized: "Цвет")
        case .gradient: String(localized: "Градиент")
        case .image: String(localized: "Картинка")
        }
    }
}

/// Готовые градиенты: от верхнего левого угла к нижнему правому.
///
/// Только спокойные: тёмные — почти чёрные, светлые — почти белые, и два
/// цвета близки друг к другу. На ярком среднем фоне (прежние «Закат»,
/// «Океан») ни светлый, ни тёмный текст панелей не читается.
struct GradientPreset: Identifiable, Hashable {
    let name: String
    let from: RGB
    let to: RGB
    var id: String { name }

    static let all: [GradientPreset] = [
        GradientPreset(name: String(localized: "Полночь"), from: RGB(hex: "#0E1626")!, to: RGB(hex: "#1D2C47")!),
        GradientPreset(name: String(localized: "Сумерки"), from: RGB(hex: "#171426")!, to: RGB(hex: "#2E2543")!),
        GradientPreset(name: String(localized: "Глубина"), from: RGB(hex: "#0B1C21")!, to: RGB(hex: "#17393F")!),
        GradientPreset(name: String(localized: "Хвоя"), from: RGB(hex: "#0F1C16")!, to: RGB(hex: "#1F3429")!),
        GradientPreset(name: String(localized: "Кофе"), from: RGB(hex: "#1C1613")!, to: RGB(hex: "#382B23")!),
        GradientPreset(name: String(localized: "Графит"), from: RGB(hex: "#15171B")!, to: RGB(hex: "#2A2D33")!),
        GradientPreset(name: String(localized: "Песок"), from: RGB(hex: "#F4EDE1")!, to: RGB(hex: "#E5D9C5")!),
        GradientPreset(name: String(localized: "Туман"), from: RGB(hex: "#EFF2F7")!, to: RGB(hex: "#D8E0EB")!),
        GradientPreset(name: String(localized: "Мята"), from: RGB(hex: "#EDF5F0")!, to: RGB(hex: "#D5E7DC")!),
        GradientPreset(name: String(localized: "Лаванда"), from: RGB(hex: "#F2EFF7")!, to: RGB(hex: "#DED7EC")!),
    ]
}

/// Готовые картинки-текстуры: лежат в приложении (`Resources/Backgrounds`),
/// рисуются кодом — `scripts/make-textures.swift`.
struct BackgroundTexture: Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [BackgroundTexture] = [
        BackgroundTexture(id: "silk", name: String(localized: "Шёлк")),
        BackgroundTexture(id: "topography", name: String(localized: "Топография")),
        BackgroundTexture(id: "nebula", name: String(localized: "Туманность")),
        BackgroundTexture(id: "slate", name: String(localized: "Сланец")),
        BackgroundTexture(id: "paper", name: String(localized: "Бумага")),
        BackgroundTexture(id: "dunes", name: String(localized: "Дюны")),
        BackgroundTexture(id: "linen", name: String(localized: "Лён")),
    ]

    /// Так текстура записана в настройке картинки фона.
    var settingName: String { Self.prefix + id }
    static let prefix = "texture:"

    /// Только из своего списка и только из приложения — не произвольный путь.
    static func named(_ setting: String?) -> BackgroundTexture? {
        guard let setting, setting.hasPrefix(prefix) else { return nil }
        return all.first { $0.settingName == setting }
    }

    var url: URL? { Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "Backgrounds") }

    /// Уменьшенная копия для галереи в настройках: полную картинку 2560 точек
    /// ради превью не читаем.
    @MainActor private static var thumbnails: [String: NSImage] = [:]

    @MainActor var thumbnail: NSImage? {
        if let cached = Self.thumbnails[id] { return cached }
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 360,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        Self.thumbnails[id] = image
        return image
    }
}

extension RGB {
    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Относительная яркость (WCAG), 0 — чёрный, 1 — белый.
    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    var hex: String {
        let value = { (component: Double) in Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value(red), value(green), value(blue))
    }

    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let number = Int(digits, radix: 16) else { return nil }
        self.init(Double((number >> 16) & 0xFF) / 255, Double((number >> 8) & 0xFF) / 255, Double(number & 0xFF) / 255)
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
    }
}

/// Своя картинка фона — только копия в папке приложения.
///
/// Безопасность: исходный файл не храним и доступа к нему не держим; копия
/// перекодируется (JPEG до 3000 точек по длинной стороне), так что внутрь
/// приложения не попадает ничего, кроме пикселей; имя в настройках — только
/// имя файла, путь собирается от своей папки и за её пределы не выходит.
enum BackgroundStore {
    static let maxInputBytes = 60 * 1024 * 1024
    static let maxSide: CGFloat = 3000

    static func folder() throws -> URL {
        let folder = try SQLiteDatabase.applicationSupportURL("Backgrounds")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Файл по имени из настроек — только внутри своей папки.
    static func url(for name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains(".."), let folder = try? folder() else { return nil }
        return folder.appendingPathComponent(name)
    }

    enum ImportError: LocalizedError {
        case tooLarge, notImage, writeFailed

        var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "Файл больше 60 МБ")
            case .notImage: String(localized: "Это не картинка, которую умеет macOS")
            case .writeFailed: String(localized: "Не удалось сохранить картинку")
            }
        }
    }

    /// Скопировать выбранную картинку к себе. Возвращает имя файла и яркость.
    static func importImage(from source: URL) throws -> (name: String, luminance: Double) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxInputBytes else { throw ImportError.tooLarge }
        guard let image = NSImage(contentsOf: source), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImportError.notImage
        }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = max(Int(CGFloat(cg.width) * scale), 1)
        let height = max(Int(CGFloat(cg.height) * scale), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImportError.writeFailed }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        else { throw ImportError.writeFailed }
        let name = "фон-\(UUID().uuidString).jpg"
        guard let url = url(for: name) else { throw ImportError.writeFailed }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImportError.writeFailed
        }
        return (name, averageLuminance(scaled))
    }

    /// Убрать свою старую картинку (только из своей папки; готовые текстуры
    /// лежат в приложении и не удаляются).
    static func remove(_ name: String?) {
        guard let name, BackgroundTexture.named(name) == nil, !name.hasPrefix(BackgroundTexture.prefix),
              let url = url(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func load(_ name: String?) -> NSImage? {
        if let texture = BackgroundTexture.named(name) {
            return texture.url.flatMap(NSImage.init(contentsOf:))
        }
        guard let name, !name.hasPrefix(BackgroundTexture.prefix), let url = url(for: name) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// Средняя яркость картинки: рисуем её в одну точку.
    static func averageLuminance(_ image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0.5 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGB(Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255).luminance
    }
}

/// Фон окна по настройке.
struct AppBackgroundView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.background {
        case .system:
            Color(nsColor: .windowBackgroundColor)
        case .sky:
            SkyBackground(scene: model.skyScene, animated: model.themeAnimated)
        case .aurora:
            AuroraBackground(intensity: 0.55, animated: model.themeAnimated)
        case .color:
            model.backgroundColor1.color.ignoresSafeArea()
        case .gradient:
            LinearGradient(colors: [model.backgroundColor1.color, model.backgroundColor2.color],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        case .image:
            ZStack {
                Color.black
                if let image = model.backgroundImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
                // Затемнение — чтобы текст на стекле читался на любой картинке.
                Color.black.opacity(model.backgroundDim)
            }
            .clipped()
            .ignoresSafeArea()
        }
    }
}

/// Оформление окна по фону: светлый фон — светлое окно, тёмный — тёмное,
/// системный — как в системе.
struct WindowAppearanceSetter: NSViewRepresentable {
    let appearance: NSAppearance.Name?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let name = appearance
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let wanted = name.flatMap(NSAppearance.init(named:))
            if window.appearance?.name != wanted?.name { window.appearance = wanted }
        }
    }
}
