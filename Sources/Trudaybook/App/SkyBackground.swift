import AppKit
import SwiftUI
import TrudaybookCore

/// Тема «Небо»: за окном — то, что сейчас снаружи. Ночью — луна в своей
/// фазе и звёзды, днём — солнце по дуге от восхода к закату, облака,
/// дождь, снег, туман и гроза — по погоде от Trunook.
///
/// Как и «сияние», всё — слоями Core Animation: кадры считает система.
/// Частота ограничена (`preferredFrameRateRange`): облака — 10 кадров
/// в секунду, снег — 20, дождь — 24 (при 30 WindowServer тратил вдвое
/// больше, чем на «сияние», а глаз разницы не видит). Выключенная анимация или «Уменьшить
/// движение» — та же картинка без движения, процессор не тратится вовсе.
struct SkyBackground: View {
    let scene: SkyScene
    var animated = true
    @ObservedObject private var motion = MotionPreference.shared

    var body: some View {
        if motion.increaseContrast {
            LinearGradient(colors: [scene.top.color, scene.bottom.color], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        } else {
            SkyLayers(scene: scene, animated: animated && !motion.reduceMotion).ignoresSafeArea()
        }
    }
}

private struct SkyLayers: NSViewRepresentable {
    let scene: SkyScene
    let animated: Bool

    func makeNSView(context: Context) -> SkyLayerView {
        let view = SkyLayerView()
        view.update(scene, animated: animated)
        return view
    }

    func updateNSView(_ view: SkyLayerView, context: Context) {
        view.update(scene, animated: animated)
    }
}

final class SkyLayerView: NSView {
    private var scene: SkyScene?
    private var animated = true
    private var builtSize: CGSize = .zero
    /// Что нарисовано слоями погоды — пересобираются, только когда это сменилось.
    private var weatherKey = ""

    private let sky = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let stars = CALayer()
    /// Крупные звёзды: у контейнера — видимость по сцене, мерцает вложенный.
    private let twinkles = CALayer()
    private let twinkleInner = CALayer()
    private let moonHalo = CAGradientLayer()
    private let moon = CALayer()
    private let sunHalo = CAGradientLayer()
    private let sun = CAGradientLayer()
    private let weather = CALayer()
    /// Сезонные украшения — над погодой: листья летят и сквозь дождь.
    private let seasonal = SeasonDecorLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        for sub in [sky, glow, stars, twinkles, moonHalo, moon, sunHalo, sun, weather, seasonal] as [CALayer] {
            root.addSublayer(sub)
        }
        twinkles.addSublayer(twinkleInner)
        sky.startPoint = CGPoint(x: 0.5, y: 0)
        sky.endPoint = CGPoint(x: 0.5, y: 1)
        for halo in [glow, moonHalo, sunHalo, sun] {
            halo.type = .radial
            halo.startPoint = CGPoint(x: 0.5, y: 0.5)
            halo.endPoint = CGPoint(x: 1, y: 1)
        }
    }

    required init?(coder: NSCoder) { fatalError("не используется") }

    override var isFlipped: Bool { true }

    /// Фон не ловит щелчки — они идут к содержимому поверх.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != builtSize, bounds.width > 0, bounds.height > 0 else { return }
        builtSize = bounds.size
        weatherKey = ""
        rebuildStatic()
        if let scene { apply(scene, transition: false) }
    }

    func update(_ scene: SkyScene, animated: Bool) {
        let changedMotion = animated != self.animated
        self.animated = animated
        guard scene != self.scene || changedMotion else { return }
        let first = self.scene == nil
        self.scene = scene
        guard bounds.width > 0 else { return }
        if changedMotion {
            weatherKey = ""
            rebuildStatic()
        }
        apply(scene, transition: !first)
    }

    // MARK: - Сцена

    private func apply(_ scene: SkyScene, transition: Bool) {
        let size = bounds.size
        CATransaction.begin()
        // Небо меняется плавно: сцена пересчитывается раз в полминуты.
        CATransaction.setAnimationDuration(transition ? 2 : 0)
        CATransaction.setDisableActions(!transition)

        sky.frame = bounds
        sky.colors = [scene.top.cgColor, scene.bottom.cgColor]

        let warmth = scene.twilight * (1 - scene.cloudCover * 0.8)
        let glowSide = max(size.width, size.height) * 1.1
        glow.bounds = CGRect(x: 0, y: 0, width: glowSide, height: glowSide * 0.7)
        glow.position = CGPoint(x: (scene.sun?.x ?? 0.5) * size.width, y: size.height)
        glow.colors = [0.55, 0.18, 0].map { NSColor(srgbRed: 1, green: 0.66, blue: 0.42, alpha: $0).cgColor }
        glow.opacity = Float(warmth)

        stars.frame = bounds
        twinkles.frame = bounds
        twinkleInner.frame = bounds
        stars.opacity = Float(scene.starVisibility)
        twinkles.opacity = Float(scene.starVisibility)

        let night = 1 - scene.daylight
        if let spot = scene.moon, scene.moonPhase > 0.03, scene.moonPhase < 0.97 {
            let center = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
            moon.position = center
            moonHalo.position = center
            let visible = Float(night * max(0, 1 - scene.cloudCover * 0.85))
            moon.opacity = visible
            moonHalo.opacity = visible * Float(0.3 + 0.7 * Self.illumination(scene.moonPhase))
        } else {
            moon.opacity = 0
            moonHalo.opacity = 0
        }

        if let spot = scene.sun {
            let center = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
            sun.position = center
            sunHalo.position = center
            let warm = RGB.mix(RGB(1, 0.97, 0.86), RGB(1, 0.66, 0.36), scene.twilight)
            sun.colors = [warm.nsColor(alpha: 1).cgColor, warm.nsColor(alpha: 1).cgColor, warm.nsColor(alpha: 0).cgColor]
            sun.locations = [0, 0.78, 1]
            sunHalo.colors = [0.5, 0.16, 0].map { warm.nsColor(alpha: $0).cgColor }
            // Сквозь тучи солнце видно пятном: диск гаснет раньше ореола.
            sun.opacity = Float(max(0, 1 - scene.cloudCover * 1.25))
            sunHalo.opacity = Float(max(0, 1 - scene.cloudCover * 0.9))
        } else {
            sun.opacity = 0
            sunHalo.opacity = 0
        }
        CATransaction.commit()

        let key = weatherSignature(scene)
        if key != weatherKey {
            weatherKey = key
            rebuildWeather(scene)
        }
        seasonal.update(season: scene.season, daylight: scene.daylight, animated: animated,
                        size: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    /// Облака и осадки пересобираются, когда сменилась погода или заметно —
    /// освещение (цвет облаков), а не каждые полминуты.
    private func weatherSignature(_ scene: SkyScene) -> String {
        "\(scene.weather.rawValue)|\(Int(scene.intensity * 10))|\(Int(scene.cloudCover * 10))|\(Int(scene.daylight * 5))|\(Int(scene.moonPhase * 30))|\(animated)|\(Int(bounds.width))x\(Int(bounds.height))"
    }

    // MARK: - Звёзды, луна, солнце

    /// Звёзды и диски — от размера окна; от сцены не зависят.
    private func rebuildStatic() {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stars.contents = Self.starImage(size: size, scale: scale, bright: false)
        twinkleInner.contents = Self.starImage(size: size, scale: scale, bright: true)
        stars.contentsScale = scale
        twinkleInner.contentsScale = scale
        twinkleInner.removeAllAnimations()
        if animated {
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 1
            twinkle.toValue = 0.25
            twinkle.duration = 2.6
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            twinkle.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 8)
            twinkleInner.add(twinkle, forKey: "twinkle")
        }

        let moonSide: CGFloat = 46
        moon.bounds = CGRect(x: 0, y: 0, width: moonSide, height: moonSide)
        moon.contentsScale = scale
        let moonHaloSide: CGFloat = 260
        moonHalo.bounds = CGRect(x: 0, y: 0, width: moonHaloSide, height: moonHaloSide)
        moonHalo.colors = [0.22, 0.07, 0].map { NSColor(srgbRed: 0.85, green: 0.9, blue: 1, alpha: $0).cgColor }

        let sunSide: CGFloat = 64
        sun.bounds = CGRect(x: 0, y: 0, width: sunSide, height: sunSide)
        let sunHaloSide = max(360, min(size.width, size.height) * 0.9)
        sunHalo.bounds = CGRect(x: 0, y: 0, width: sunHaloSide, height: sunHaloSide)
        CATransaction.commit()
    }

    static func illumination(_ phase: Double) -> Double { (1 - cos(2 * .pi * phase)) / 2 }

    private static func context(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGContext? {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    /// Звёзды одним рисунком: одно и то же небо при каждом запуске,
    /// гуще наверху. `bright` — редкие крупные, они мерцают.
    private static func starImage(size: CGSize, scale: CGFloat, bright: Bool) -> CGImage? {
        guard let context = context(width: size.width, height: size.height, scale: scale) else { return nil }
        var random = SeededRandom(bright ? 0x9E37_79B9 : 0x2545_F491)
        let count = Int(size.width * size.height / (bright ? 60_000 : 5_500))
        for _ in 0..<count {
            let x = random.next() * size.width
            // Гуще наверху; у контекста ноль внизу — считаем от верхнего края.
            let fromTop = pow(random.next(), 1.6) * size.height * 0.85
            let radius = bright ? 0.9 + random.next() * 0.8 : 0.35 + random.next() * 0.6
            let alpha = bright ? 0.9 : 0.35 + random.next() * 0.5
            context.setFillColor(NSColor(srgbRed: 0.92, green: 0.95, blue: 1, alpha: alpha).cgColor)
            context.fillEllipse(in: CGRect(x: x - radius, y: size.height - fromTop - radius, width: radius * 2, height: radius * 2))
        }
        return context.makeImage()
    }

    /// Луна в своей фазе: освещённая часть — полукруг и эллипс терминатора;
    /// тёмная часть чуть видна (пепельный свет). Растущая — светлая справа.
    private static func moonImage(side: CGFloat, scale: CGFloat, phase: Double) -> CGImage? {
        guard let context = context(width: side, height: side, scale: scale) else { return nil }
        let radius = side / 2 - 1
        let center = CGPoint(x: side / 2, y: side / 2)
        context.setFillColor(NSColor(srgbRed: 0.8, green: 0.84, blue: 0.92, alpha: 0.1).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        let waxing = phase < 0.5
        let direction: CGFloat = waxing ? 1 : -1
        let terminator = CGFloat(cos(2 * .pi * phase))
        let path = CGMutablePath()
        let steps = 48
        path.move(to: CGPoint(x: center.x, y: center.y + radius))
        for step in 0...steps {
            let angle = Double.pi * Double(step) / Double(steps)
            path.addLine(to: CGPoint(x: center.x + direction * radius * CGFloat(sin(angle)),
                                     y: center.y + radius * CGFloat(cos(angle))))
        }
        for step in stride(from: steps, through: 0, by: -1) {
            let angle = Double.pi * Double(step) / Double(steps)
            path.addLine(to: CGPoint(x: center.x + direction * terminator * radius * CGFloat(sin(angle)),
                                     y: center.y + radius * CGFloat(cos(angle))))
        }
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(NSColor(srgbRed: 0.97, green: 0.96, blue: 0.9, alpha: 1).cgColor)
        context.fillPath()
        return context.makeImage()
    }

    // MARK: - Погода

    private func rebuildWeather(_ scene: SkyScene) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        weather.sublayers?.forEach { $0.removeFromSuperlayer() }
        weather.frame = bounds
        weather.masksToBounds = true
        let scale = window?.backingScaleFactor ?? 2
        // Фаза луны меняется медленно — рисунок обновляется вместе с погодой.
        moon.contents = Self.moonImage(side: moon.bounds.width, scale: scale, phase: scene.moonPhase)

        if scene.weather == .fog { addFog(scene) }
        addClouds(scene, scale: scale)
        switch scene.weather {
        case .rain, .thunder:
            addPrecipitation(snow: false, intensity: scene.intensity, daylight: scene.daylight, scale: scale)
        case .drizzle:
            addPrecipitation(snow: false, intensity: scene.intensity * 0.5, daylight: scene.daylight, scale: scale)
        case .snow:
            addPrecipitation(snow: true, intensity: scene.intensity, daylight: scene.daylight, scale: scale)
        default:
            break
        }
        if scene.weather == .thunder { addLightning() }
        CATransaction.commit()
    }

    /// Облака — мягкие комки из кругов с размытым краем. Плывут вправо,
    /// каждое своим ходом; уходя за край, возвращаются слева.
    private func addClouds(_ scene: SkyScene, scale: CGFloat) {
        let count: Int = switch scene.cloudCover {
        case ..<0.1: 0
        case ..<0.3: 3
        case ..<0.5: 5
        case ..<0.8: 8
        default: 11
        }
        guard count > 0 else { return }
        let size = bounds.size
        // Днём облака белые, тучи — серые (снеговые — светлее дождевых),
        // ночью — едва светлее неба. Снежинки и капли должны быть видны
        // на них, поэтому тучи не белые.
        let heavy = scene.cloudCover > 0.8
        let dayTone = !heavy ? RGB(1, 1, 1) : scene.weather == .snow ? RGB(0.8, 0.83, 0.88) : RGB(0.66, 0.7, 0.76)
        var tone = RGB.mix(RGB(0.24, 0.27, 0.33), dayTone, scene.daylight)
        if scene.weather == .thunder { tone = RGB.mix(tone, RGB(0.3, 0.33, 0.38), 0.6) }
        let alpha = heavy ? 0.85 : 0.9

        var random = SeededRandom(UInt64(count) &* 0x51_7CC1)
        for index in 0..<count {
            let width = size.width * (heavy ? 0.4 + random.next() * 0.3 : 0.22 + random.next() * 0.18)
            let height = width * 0.42
            let cloud = CALayer()
            cloud.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            cloud.contentsScale = scale
            cloud.contents = Self.cloudImage(size: cloud.bounds.size, scale: scale, tone: tone, alpha: alpha,
                                             seed: UInt64(index + 1))
            let y = size.height * (heavy ? -0.05 + random.next() * 0.5 : 0.04 + random.next() * 0.38)
            let startX = -width / 2
            let endX = size.width + width / 2
            let spread = random.next()
            cloud.position = CGPoint(x: startX + (endX - startX) * spread, y: y)
            cloud.opacity = Float(0.75 + random.next() * 0.25)
            weather.addSublayer(cloud)
            guard animated else { continue }
            // Ближние — крупнее и быстрее; круг — 4–9 минут.
            let duration = 240 + 300 * (1 - width / size.width) + random.next() * 60
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = startX
            drift.toValue = endX
            drift.duration = duration
            drift.repeatCount = .infinity
            drift.timeOffset = duration * spread
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 12, preferred: 10)
            cloud.add(drift, forKey: "drift")
        }
    }

    private static func cloudImage(size: CGSize, scale: CGFloat, tone: RGB, alpha: Double, seed: UInt64) -> CGImage? {
        guard let context = context(width: size.width, height: size.height, scale: scale) else { return nil }
        var random = SeededRandom(seed &* 0x2545_F491_4F6C_DD1D)
        let colors = [tone.nsColor(alpha: alpha).cgColor, tone.nsColor(alpha: alpha * 0.6).cgColor,
                      tone.nsColor(alpha: 0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.55, 1]) else { return nil }
        // Комки по нижней линии и повыше к середине — силуэт кучевого облака.
        let puffs = 9
        for index in 0..<puffs {
            let t = Double(index) / Double(puffs - 1)
            let hump = sin(t * .pi)
            let radius = size.height * (0.28 + 0.24 * hump + random.next() * 0.08)
            let x = size.width * (0.14 + 0.72 * t) + (random.next() - 0.5) * size.width * 0.05
            let y = size.height * (0.32 + 0.18 * hump * random.next())
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                       endCenter: CGPoint(x: x, y: y), endRadius: radius, options: [])
        }
        return context.makeImage()
    }

    /// Дождь и снег — полотнами из одинаковых плиток, которые съезжают вниз
    /// на высоту плитки и начинают заново: шва не видно, а движение —
    /// одна анимация на полотно. Два полотна — ближнее и дальнее.
    private func addPrecipitation(snow: Bool, intensity: Double, daylight: Double, scale: CGFloat) {
        let size = bounds.size
        let tile: CGFloat = 420
        for (depth, near) in [(0, false), (1, true)] {
            let density = intensity * (near ? 0.55 : 1)
            guard let image = Self.precipitationTile(width: size.width, height: tile, scale: scale, snow: snow,
                                                      near: near, density: density, daylight: daylight,
                                                      seed: UInt64(depth + 7)) else { continue }
            let sheet = CALayer()
            let rows = Int(ceil(size.height / tile)) + 1
            sheet.frame = CGRect(x: 0, y: -tile, width: size.width, height: tile * CGFloat(rows))
            for row in 0..<rows {
                let piece = CALayer()
                piece.frame = CGRect(x: 0, y: CGFloat(row) * tile, width: size.width, height: tile)
                piece.contents = image
                piece.contentsScale = scale
                sheet.addSublayer(piece)
            }
            weather.addSublayer(sheet)
            guard animated else { continue }
            let speed: CGFloat = snow ? (near ? 46 : 26) : (near ? 760 : 520)
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = sheet.position.y
            fall.toValue = sheet.position.y + tile
            fall.duration = Double(tile / speed)
            fall.repeatCount = .infinity
            fall.preferredFrameRateRange = snow
                ? CAFrameRateRange(minimum: 12, maximum: 24, preferred: 20)
                : CAFrameRateRange(minimum: 18, maximum: 24, preferred: 24)
            sheet.add(fall, forKey: "fall")
            if snow {
                // Снег покачивается из стороны в сторону.
                let sway = CABasicAnimation(keyPath: "position.x")
                sway.fromValue = sheet.position.x - (near ? 14 : 8)
                sway.toValue = sheet.position.x + (near ? 14 : 8)
                sway.duration = near ? 3.8 : 5.2
                sway.autoreverses = true
                sway.repeatCount = .infinity
                sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sway.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 24, preferred: 20)
                sheet.add(sway, forKey: "sway")
            }
        }
    }

    private static func precipitationTile(width: CGFloat, height: CGFloat, scale: CGFloat, snow: Bool, near: Bool,
                                          density: Double, daylight: Double, seed: UInt64) -> CGImage? {
        guard let context = context(width: width, height: height, scale: scale) else { return nil }
        var random = SeededRandom(seed &* 0x9E37_79B9_7F4A_7C15)
        // Днём капли темнее неба, ночью — светлее: иначе их не видно.
        let drop = daylight > 0.5 ? RGB(0.26, 0.33, 0.45) : RGB(0.78, 0.84, 0.95)
        let area = width * height
        if snow {
            let count = Int(area / 5_200 * density)
            context.setFillColor(NSColor(white: 1, alpha: near ? 0.9 : 0.6).cgColor)
            for _ in 0..<count {
                let radius = near ? 1.8 + random.next() * 1.8 : 0.9 + random.next() * 1.1
                let x = random.next() * width
                let y = random.next() * height
                // Плитка повторяется по вертикали: снежинка у края — и с той стороны.
                for shift in [-height, 0, height] {
                    context.fillEllipse(in: CGRect(x: x - radius, y: y + shift - radius, width: radius * 2, height: radius * 2))
                }
            }
        } else {
            let count = Int(area / (near ? 5_000 : 2_600) * density)
            context.setLineCap(.round)
            context.setStrokeColor(drop.nsColor(alpha: near ? 0.62 : 0.4).cgColor)
            context.setLineWidth(near ? 1.5 : 1)
            for _ in 0..<count {
                let length = near ? 18 + random.next() * 12 : 10 + random.next() * 8
                let x = random.next() * width
                let y = random.next() * height
                // Косой дождь — чуть влево; у контекста ноль внизу.
                for shift in [-height, 0, height] {
                    context.move(to: CGPoint(x: x, y: y + shift))
                    context.addLine(to: CGPoint(x: x - length * 0.18, y: y + shift - length))
                }
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    /// Туман — две широкие полосы у горизонта, едва плывут.
    private func addFog(_ scene: SkyScene) {
        let size = bounds.size
        for (index, level) in [0.58, 0.8].enumerated() {
            let band = CAGradientLayer()
            band.type = .radial
            band.startPoint = CGPoint(x: 0.5, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 1)
            let tone = RGB.mix(RGB(0.5, 0.54, 0.6), RGB(0.97, 0.97, 0.98), scene.daylight)
            band.colors = [0.55, 0.3, 0].map { tone.nsColor(alpha: $0).cgColor }
            band.bounds = CGRect(x: 0, y: 0, width: size.width * 1.7, height: size.height * 0.45)
            band.position = CGPoint(x: size.width / 2, y: size.height * level)
            weather.addSublayer(band)
            guard animated else { continue }
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = size.width * (index == 0 ? 0.38 : 0.62)
            drift.toValue = size.width * (index == 0 ? 0.62 : 0.38)
            drift.duration = 70 + Double(index) * 25
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 12, preferred: 10)
            band.add(drift, forKey: "drift")
        }
    }

    /// Гроза — редкие вспышки: две быстрые подряд раз в 13 секунд.
    private func addLightning() {
        guard animated else { return }
        let flash = CALayer()
        flash.frame = bounds
        flash.backgroundColor = NSColor(white: 1, alpha: 1).cgColor
        flash.opacity = 0
        weather.addSublayer(flash)
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [0, 0, 0.4, 0, 0.25, 0, 0]
        blink.keyTimes = [0, 0.7, 0.705, 0.715, 0.725, 0.74, 1]
        blink.duration = 13
        blink.repeatCount = .infinity
        blink.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        flash.add(blink, forKey: "blink")
    }
}

/// Повторяемый случайный ряд: одно и то же небо при каждом запуске.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed | 1 }

    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

extension RGB {
    var cgColor: CGColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).cgColor }

    func nsColor(alpha: Double) -> NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let k = min(max(t, 0), 1)
        return RGB(a.red + (b.red - a.red) * k, a.green + (b.green - a.green) * k, a.blue + (b.blue - a.blue) * k)
    }
}
