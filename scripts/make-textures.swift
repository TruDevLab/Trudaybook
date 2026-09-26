// Готовые фоны-текстуры рисуются кодом: поправить здесь и `make textures`.
// Все спокойные и низкоконтрастные — под стеклянными панелями текст должен
// читаться: тёмные почти чёрные, светлые почти белые.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 2560
let height = 1600

// MARK: - Шум

struct Noise {
    let seed: UInt32

    func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393 &+ y &* 668_265_263) &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    func value(_ x: Float, _ y: Float) -> Float {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let xi = Int32(xf), yi = Int32(yf)
        let tx = x - xf, ty = y - yf
        let u = tx * tx * (3 - 2 * tx), v = ty * ty * (3 - 2 * ty)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    /// Сумма октав, 0…1.
    func fbm(_ x: Float, _ y: Float, octaves: Int = 5) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, frequency: Float = 1, norm: Float = 0
        for octave in 0..<octaves {
            sum += amplitude * value(x * frequency + Float(octave) * 17.3, y * frequency - Float(octave) * 9.1)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2.02
        }
        return sum / norm
    }
}

struct RGB {
    var r: Float, g: Float, b: Float
    init(_ hex: UInt32) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
    }
    init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
    static func mix(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }
    func scaled(_ k: Float) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    func plus(_ k: Float) -> RGB { RGB(r: r + k, g: g + k, b: b + k) }
}

/// Цвет по шкале: точки (t, цвет), t по возрастанию.
func ramp(_ stops: [(Float, RGB)], _ t: Float) -> RGB {
    let t = min(max(t, 0), 1)
    for index in 1..<stops.count where t <= stops[index].0 {
        let (t0, c0) = stops[index - 1], (t1, c1) = stops[index]
        return RGB.mix(c0, c1, (t - t0) / max(t1 - t0, 0.0001))
    }
    return stops.last!.1
}

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

func fract(_ x: Float) -> Float { x - x.rounded(.down) }

// MARK: - Текстуры

typealias Shader = (_ x: Float, _ y: Float) -> RGB

let n1 = Noise(seed: 11), n2 = Noise(seed: 29), n3 = Noise(seed: 47), grain = Noise(seed: 83)

/// Мелкое зерно, ±amount — чтобы градиенты не шли полосами.
func dither(_ x: Float, _ y: Float, _ amount: Float) -> Float {
    (grain.hash(Int32(x), Int32(y)) - 0.5) * amount
}

let textures: [(String, Shader)] = [
    // Шёлк: складки тёмной ткани — шум, закрученный шумом.
    ("silk", { x, y in
        let s: Float = 0.0011
        let wx = n1.fbm(x * s, y * s, octaves: 4), wy = n2.fbm(x * s + 5.2, y * s + 1.3, octaves: 4)
        let v = n3.fbm(x * s * 1.3 + 3.2 * wx, y * s * 1.3 + 3.2 * wy, octaves: 5)
        let sheen = pow(smoothstep(0.5, 0.75, v), 2) * 0.07
        return ramp([(0, RGB(0x0F1115)), (0.45, RGB(0x1A1F2A)), (1, RGB(0x333C52))], smoothstep(0.25, 0.75, v))
            .plus(sheen + dither(x, y, 0.012))
    }),
    // Топография: горизонтали на тёмном сланце, каждая пятая — ярче.
    ("topography", { x, y in
        let s: Float = 0.0008
        let h = n1.fbm(x * s, y * s, octaves: 5)
        let level = h * 16
        // Толщина линии — в точках, по крутизне склона: на пологом месте
        // линия не расплывается пятном.
        let dx = (n1.fbm((x + 1) * s, y * s, octaves: 5) - h) * 16
        let dy = (n1.fbm(x * s, (y + 1) * s, octaves: 5) - h) * 16
        let slope = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let distance = min(fract(level), 1 - fract(level)) / slope
        let major = Int(level.rounded()) % 5 == 0
        let line = 1 - smoothstep(major ? 0.9 : 0.5, major ? 2.0 : 1.4, distance)
        let base = ramp([(0, RGB(0x10171C)), (1, RGB(0x1A252D))], h)
        return RGB.mix(base, RGB(major ? 0x3A5563 : 0x2A3D48), line * (major ? 0.8 : 0.6))
            .plus(dither(x, y, 0.01))
    }),
    // Туманность: тёмные облака индиго и бирюзы.
    ("nebula", { x, y in
        let s: Float = 0.0009
        let wx = n2.fbm(x * s, y * s, octaves: 4)
        let cloud = n1.fbm(x * s * 1.1 + 2.5 * wx, y * s * 1.1 - 2.5 * wx, octaves: 6)
        let hue = n3.fbm(x * s * 0.6, y * s * 0.6, octaves: 3)
        let v = smoothstep(0.28, 0.72, cloud)
        let violet = ramp([(0, RGB(0x0C0B18)), (0.55, RGB(0x19142F)), (1, RGB(0x2C2150))], v)
        let teal = ramp([(0, RGB(0x0A1218)), (0.55, RGB(0x10232E)), (1, RGB(0x173B48))], v)
        return RGB.mix(violet, teal, smoothstep(0.35, 0.65, hue)).plus(dither(x, y, 0.012))
    }),
    // Сланец: слоистый серый камень с мелким зерном.
    ("slate", { x, y in
        let broad = n1.fbm(x * 0.0015, y * 0.0015, octaves: 4)
        let layers = n2.fbm(x * 0.0006, y * 0.009, octaves: 4)
        let fine = n3.fbm(x * 0.03, y * 0.03, octaves: 2)
        let v = smoothstep(0.3, 0.7, broad * 0.5 + layers * 0.35 + fine * 0.15)
        return ramp([(0, RGB(0x17191C)), (0.5, RGB(0x202327)), (1, RGB(0x2D3136))], v)
            .plus(dither(x, y, 0.02))
    }),
    // Бумага: тёплый лист с волокнами и зерном.
    ("paper", { x, y in
        let blotch = n1.fbm(x * 0.002, y * 0.002, octaves: 4)
        // Волокна — короткие и тонкие, в разные стороны.
        let fibers = max(n2.fbm(x * 0.09, y * 0.014, octaves: 2), n3.fbm(x * 0.014, y * 0.09, octaves: 2))
        let base = RGB(0xEFE9DE)
        return base.scaled(0.975 + blotch * 0.035 - smoothstep(0.7, 0.85, fibers) * 0.018)
            .plus(dither(x, y, 0.03))
    }),
    // Дюны: песчаная рябь волнами.
    ("dunes", { x, y in
        let s: Float = 0.0011
        let warp = n1.fbm(x * s, y * s, octaves: 4)
        let ripple = 0.5 + 0.5 * sin((y * 0.018 + warp * 9 + x * 0.002) * 2)
        let shade = n2.fbm(x * 0.0007, y * 0.0007, octaves: 3)
        let base = ramp([(0, RGB(0xDCCBB2)), (1, RGB(0xF0E6D6))], ripple * 0.7 + shade * 0.3)
        return base.plus(dither(x, y, 0.02))
    }),
    // Лён: переплетение нитей с утолщениями.
    ("linen", { x, y in
        let jitterX = n1.fbm(x * 0.01, y * 0.3, octaves: 2) * 2
        let jitterY = n2.fbm(x * 0.3, y * 0.01, octaves: 2) * 2
        let warp = 0.5 + 0.5 * sin((x + jitterX) * 1.1)
        let weft = 0.5 + 0.5 * sin((y + jitterY) * 1.1)
        let slub = n3.fbm(x * 0.004, y * 0.08, octaves: 3)
        let weave = (warp * 0.5 + weft * 0.5)
        return RGB(0xECE7DE).scaled(0.955 + weave * 0.045 + slub * 0.025).plus(dither(x, y, 0.015))
    }),
]

// MARK: - Запись

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Backgrounds")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for (name, shader) in textures {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    pixels.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width {
                let color = shader(Float(x), Float(y))
                let offset = (y * width + x) * 4
                base[offset] = UInt8(min(max(color.r, 0), 1) * 255)
                base[offset + 1] = UInt8(min(max(color.g, 0), 1) * 255)
                base[offset + 2] = UInt8(min(max(color.b, 0), 1) * 255)
            }
        }
    }
    let data = Data(pixels) as CFData
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)!
    let url = output.appendingPathComponent("\(name).jpg")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
    CGImageDestinationFinalize(destination)
    print("текстура: \(url.lastPathComponent)")
}
