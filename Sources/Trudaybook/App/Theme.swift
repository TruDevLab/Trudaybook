import AppKit
import CoreImage
import SwiftUI

/// Оформление из Trunook: те же цвета и то же «сияние» за окном — чтобы
/// Trudaybook рядом с вырезом выглядел частью одной семьи.
/// Источник — `Trunook/Sources/Trunook/Core/{Palette,AuroraBackground}.swift`.
enum Palette {
    static let cyan = Color(red: 0.36, green: 0.86, blue: 1.0)
    static let violet = Color(red: 0.62, green: 0.44, blue: 1.0)
    static let mint = Color(red: 0.42, green: 0.95, blue: 0.75)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.35)
    static let rose = Color(red: 1.0, green: 0.45, blue: 0.5)
    static let blue = Color(red: 0.36, green: 0.55, blue: 1.0)
    /// Почти чёрный с синевой — основа, на которой светятся пятна.
    static let windowBase = Color(red: 0.035, green: 0.043, blue: 0.075)
}

/// «Уменьшить движение» и «увеличить контраст» из Универсального доступа.
@MainActor
final class MotionPreference: ObservableObject {
    static let shared = MotionPreference()

    @Published private(set) var reduceMotion: Bool
    @Published private(set) var increaseContrast: Bool
    private var observer: NSObjectProtocol?

    private init() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
        }
    }
}

/// Медленно плывущие пятна света на почти чёрном фоне — как в окнах Trunook.
///
/// `animated == false` (или «уменьшить движение») — пятна замирают на одном
/// кадре: картинка та же, а процессор не тратится вовсе.
struct AuroraBackground: View {
    /// Во сколько раз тише обычного светить: под мелким текстом пятна приглушены.
    var intensity: Double = 1
    var animated = true

    /// Кадр, на котором замирает фон: в нуле пятна стоят симметрично.
    private static let stillFrame: TimeInterval = 7

    @ObservedObject private var motion = MotionPreference.shared

    private var isStill: Bool { !animated || motion.reduceMotion }

    var body: some View {
        if motion.increaseContrast {
            Palette.windowBase.ignoresSafeArea()
        } else if isStill {
            frame(at: Self.stillFrame)
        } else {
            // Движение — анимациями Core Animation: кадры считает система,
            // а не приложение. Перерисовка из SwiftUI (`TimelineView`)
            // стоила главному окну около 12 % ядра даже при 12 кадрах в секунду.
            AuroraLayers(intensity: intensity).ignoresSafeArea()
        }
    }

    private func frame(at time: TimeInterval) -> some View {
        GeometryReader { proxy in
            ZStack {
                Palette.windowBase
                blob(Palette.violet, size: proxy.size, at: drift(time, speed: 0.05, phase: 0.0, spread: 0.28, center: CGPoint(x: 0.24, y: 0.28)), scale: 1.15)
                blob(Palette.cyan, size: proxy.size, at: drift(time, speed: 0.037, phase: 2.1, spread: 0.24, center: CGPoint(x: 0.78, y: 0.22)), scale: 0.95)
                blob(Palette.mint, size: proxy.size, at: drift(time, speed: 0.029, phase: 4.3, spread: 0.2, center: CGPoint(x: 0.6, y: 0.92)), scale: 0.8)
                vignette(size: proxy.size)
            }
        }
        .ignoresSafeArea()
    }

    /// Точка по фигуре Лиссажу: путь не повторяется на глаз, а кадр — чистая функция времени.
    private func drift(_ time: TimeInterval, speed: Double, phase: Double, spread: Double, center: CGPoint) -> CGPoint {
        CGPoint(
            x: center.x + spread * sin(time * speed * 2 * .pi + phase),
            y: center.y + spread * 0.6 * cos(time * speed * 3 * .pi + phase * 1.7)
        )
    }

    private func blob(_ color: Color, size: CGSize, at unit: CGPoint, scale: CGFloat) -> some View {
        let side = max(size.width, size.height) * 1.05 * scale
        return RadialGradient(
            colors: [color.opacity(0.5 * intensity), color.opacity(0.14 * intensity), color.opacity(0)],
            center: .center, startRadius: 0, endRadius: side / 2
        )
        .frame(width: side, height: side)
        .position(x: unit.x * size.width, y: unit.y * size.height)
        .blendMode(.plusLighter)
    }

    private func vignette(size: CGSize) -> some View {
        RadialGradient(
            colors: [Color.clear, Color.black.opacity(0.6)],
            center: .center,
            startRadius: min(size.width, size.height) * 0.35,
            endRadius: max(size.width, size.height) * 0.75
        )
    }
}

/// Те же три пятна и затемнение по краям, но слоями Core Animation:
/// каждое пятно идёт по своей фигуре Лиссажу бесконечной анимацией позиции.
/// Путь замкнут (за `2 / speed` секунд по x — два оборота, по y — три),
/// поэтому повтор без шва.
private struct AuroraLayers: NSViewRepresentable {
    let intensity: Double

    func makeNSView(context: Context) -> AuroraLayerView {
        let view = AuroraLayerView()
        view.intensity = intensity
        return view
    }

    func updateNSView(_ view: AuroraLayerView, context: Context) {
        if view.intensity != intensity {
            view.intensity = intensity
            view.needsLayout = true
        }
    }
}

final class AuroraLayerView: NSView {
    var intensity: Double = 1
    private var builtFor: CGSize = .zero

    private struct Blob {
        let color: NSColor
        let speed: Double
        let phase: Double
        let spread: Double
        let center: CGPoint
        let scale: CGFloat
    }

    private static let blobs = [
        Blob(color: NSColor(srgbRed: 0.62, green: 0.44, blue: 1.0, alpha: 1), speed: 0.05, phase: 0.0, spread: 0.28,
             center: CGPoint(x: 0.24, y: 0.28), scale: 1.15),
        Blob(color: NSColor(srgbRed: 0.36, green: 0.86, blue: 1.0, alpha: 1), speed: 0.037, phase: 2.1, spread: 0.24,
             center: CGPoint(x: 0.78, y: 0.22), scale: 0.95),
        Blob(color: NSColor(srgbRed: 0.42, green: 0.95, blue: 0.75, alpha: 1), speed: 0.029, phase: 4.3, spread: 0.2,
             center: CGPoint(x: 0.6, y: 0.92), scale: 0.8),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("не используется") }

    override var isFlipped: Bool { true }

    /// Фон не ловит щелчки — они идут к содержимому поверх.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Слои пересобираются только при смене размера: анимации идут сами.
        guard bounds.size != builtFor, bounds.width > 0, bounds.height > 0 else { return }
        builtFor = bounds.size
        rebuild()
    }

    private func rebuild() {
        guard let root = layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.backgroundColor = NSColor(srgbRed: 0.035, green: 0.043, blue: 0.075, alpha: 1).cgColor
        let size = bounds.size

        for blob in Self.blobs {
            let side = max(size.width, size.height) * 1.05 * blob.scale
            let gradient = CAGradientLayer()
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.colors = [0.5, 0.14, 0].map { blob.color.withAlphaComponent($0 * intensity).cgColor }
            gradient.locations = [0, 0.5, 1]
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.compositingFilter = CIFilter(name: "CIAdditionCompositing")
            gradient.position = point(blob, at: 0, in: size)

            let period = 2 / blob.speed
            let steps = 240
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = (0...steps).map { NSValue(point: point(blob, at: period * Double($0) / Double(steps), in: size)) }
            move.duration = period
            move.calculationMode = .linear
            move.repeatCount = .infinity
            move.isRemovedOnCompletion = false
            // Пятна плывут медленно: 12 кадров хватает глазу, а экран в 120 Гц
            // иначе перерисовывал бы всё окно в десять раз чаще.
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            // Тот же отсчёт, что у неподвижного кадра: пятна не прыгают при включении.
            move.timeOffset = 7
            gradient.add(move, forKey: "drift")
            root.addSublayer(gradient)
        }

        let side = max(size.width, size.height) * 1.5
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)
        vignette.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.6).cgColor]
        vignette.locations = [0, NSNumber(value: min(1, min(size.width, size.height) * 0.35 / (side / 2))), 1]
        vignette.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        vignette.position = CGPoint(x: size.width / 2, y: size.height / 2)
        root.addSublayer(vignette)
    }

    private func point(_ blob: Blob, at time: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (blob.center.x + blob.spread * sin(time * blob.speed * 2 * .pi + blob.phase)) * size.width,
            y: (blob.center.y + blob.spread * 0.6 * cos(time * blob.speed * 3 * .pi + blob.phase * 1.7)) * size.height
        )
    }
}

/// Карточка раздела настроек — как сгруппированная форма в Trunook:
/// подпись со значком над полупрозрачной подложкой.
struct SettingsCard<Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(GlassPanelBackground(cornerRadius: 10))
        }
    }
}

/// Пояснение под настройкой.
struct SettingsHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
