import AppKit
import TrudaybookCore

/// Сезонные украшения темы «Небо» — поверх неба и погоды, под панелями.
///
/// Осенью падают разноцветные листья и лежат кучкой внизу, зимой окно
/// по краям замерзает узором инея, весной в нижних углах цветут деревья и
/// летят лепестки, летом внизу — луг с цветами, который колышет ветер.
///
/// Всё нарисовано один раз картинками, движение — анимациями Core
/// Animation с ограниченной частотой кадров (листья — до 24 в секунду,
/// луг — до 12), как облака и снег. Ночью украшения темнеют вместе
/// с небом. Без анимации — та же сцена неподвижно.
final class SeasonDecorLayer: CALayer {
    private var key = ""

    func update(season: SkyScene.Season?, daylight: Double, animated: Bool, size: CGSize, scale: CGFloat) {
        let newKey = "\(season?.rawValue ?? "-")|\(Int(daylight * 5))|\(animated)|\(Int(size.width))x\(Int(size.height))"
        guard newKey != key, size.width > 0, size.height > 0 else { return }
        key = newKey
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sublayers?.forEach { $0.removeFromSuperlayer() }
        frame = CGRect(origin: .zero, size: size)
        masksToBounds = true
        let light = 0.35 + 0.65 * min(max(daylight, 0), 1)
        switch season {
        case .autumn?: addAutumn(size: size, scale: scale, light: light, animated: animated)
        case .winter?: addWinter(size: size, scale: scale, light: light, animated: animated)
        case .spring?: addSpring(size: size, scale: scale, light: light, animated: animated)
        case .summer?: addSummer(size: size, scale: scale, light: light, animated: animated)
        case nil: break
        }
        CATransaction.commit()
    }

    /// Цвет днём — как есть, ночью — к тёмно-синему, как всё за окном.
    private static func tone(_ color: RGB, _ light: Double) -> RGB {
        RGB.mix(RGB(0.1, 0.12, 0.18), color, light)
    }

    /// Холст, где ноль — сверху слева: так проще думать о раскладке.
    private static func canvas(_ size: CGSize, scale: CGFloat) -> CGContext? {
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        return context
    }

    // MARK: - Падающее: листья и лепестки

    /// Падает сверху вниз, покачиваясь из стороны в сторону, вращаясь и
    /// переворачиваясь; уйдя за нижний край, начинает сверху заново.
    private func addFalling(_ piece: CALayer, size: CGSize, random: inout SeededRandom, animated: Bool,
                            duration: ClosedRange<Double>, sway: ClosedRange<Double>) {
        let side = piece.bounds.width
        let startX = random.next() * size.width
        addSublayer(piece)
        guard animated else {
            piece.position = CGPoint(x: startX, y: random.next() * size.height * 0.9)
            piece.transform = CATransform3DMakeRotation(random.next() * .pi * 2, 0, 0, 1)
            return
        }
        piece.position = CGPoint(x: startX, y: -side)
        let amplitude = sway.lowerBound + random.next() * (sway.upperBound - sway.lowerBound)
        let drift = (random.next() - 0.35) * size.width * 0.22
        let waves = 2.5 + random.next() * 2
        let phase = random.next() * .pi * 2
        let path = CGMutablePath()
        let steps = 48
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let point = CGPoint(x: startX + drift * t + amplitude * sin(t * waves * .pi * 2 + phase),
                                y: -side + (size.height + side * 2) * t)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let fall = CAKeyframeAnimation(keyPath: "position")
        fall.path = path
        fall.calculationMode = .paced

        let turns = (1 + random.next() * 2.5) * (random.next() < 0.5 ? -1 : 1)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = turns * .pi * 2

        // Лист переворачивается в воздухе: сужается и снова раскрывается.
        let flip = CAKeyframeAnimation(keyPath: "transform.scale.x")
        flip.values = [1, 0.25, 1, 0.5, 1, 0.2, 1]
        flip.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [fall, spin, flip]
        group.duration = duration.lowerBound + random.next() * (duration.upperBound - duration.lowerBound)
        for animation in group.animations ?? [] { animation.duration = group.duration }
        group.repeatCount = .infinity
        group.timeOffset = group.duration * random.next()
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 24, preferred: 20)
        piece.add(group, forKey: "fall")
    }

    // MARK: - Осень

    private static let autumnColors = [RGB(0.93, 0.52, 0.13), RGB(0.84, 0.24, 0.12), RGB(0.97, 0.78, 0.22),
                                       RGB(0.64, 0.38, 0.16), RGB(0.74, 0.14, 0.2), RGB(0.9, 0.62, 0.18)]

    private func addAutumn(size: CGSize, scale: CGFloat, light: Double, animated: Bool) {
        // Кучка опавших листьев вдоль нижнего края.
        let pileHeight: CGFloat = 64
        let pile = CALayer()
        pile.frame = CGRect(x: 0, y: size.height - pileHeight, width: size.width, height: pileHeight)
        pile.contents = Self.leafPile(CGSize(width: size.width, height: pileHeight), scale: scale, light: light)
        pile.contentsScale = scale
        addSublayer(pile)

        var random = SeededRandom(0xA17_0F3)
        // За стеклом панелей лист размывается — поэтому крупнее и чаще,
        // чем было бы на открытом фоне.
        let count = max(14, min(34, Int(size.width / 55)))
        for index in 0..<count {
            let side = 24 + random.next() * 20
            let leaf = CALayer()
            leaf.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            leaf.contentsScale = scale
            let color = Self.tone(Self.autumnColors[index % Self.autumnColors.count], light)
            leaf.contents = Self.leafImage(side: side, scale: scale, color: color, maple: index % 3 == 0)
            leaf.opacity = 0.95
            addFalling(leaf, size: size, random: &random, animated: animated, duration: 16...28, sway: 25...70)
        }
    }

    private static func leafImage(side: CGFloat, scale: CGFloat, color: RGB, maple: Bool) -> CGImage? {
        guard let context = canvas(CGSize(width: side, height: side), scale: scale) else { return nil }
        drawLeaf(context, center: CGPoint(x: side / 2, y: side / 2), size: side * 0.92, angle: 0, color: color, maple: maple)
        return context.makeImage()
    }

    /// Лист: овальный (берёза, тополь) или кленовый — пять лопастей. С
    /// черешком и прожилками потемнее.
    private static func drawLeaf(_ context: CGContext, center: CGPoint, size: CGFloat, angle: CGFloat,
                                 color: RGB, maple: Bool) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        let half = size / 2
        let vein = RGB.mix(color, RGB(0.25, 0.12, 0.05), 0.45)
        let path = CGMutablePath()
        if maple {
            let lobes = 5
            for index in 0..<(lobes * 2) {
                let outer = index % 2 == 0
                let radius = outer ? half * (index == 0 ? 1 : 0.88) : half * 0.42
                let a = -CGFloat.pi / 2 + CGFloat(index) * .pi / CGFloat(lobes)
                let point = CGPoint(x: cos(a) * radius, y: sin(a) * radius * 0.95)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: 0, y: -half))
            path.addCurve(to: CGPoint(x: 0, y: half * 0.72), control1: CGPoint(x: half * 0.95, y: -half * 0.35),
                          control2: CGPoint(x: half * 0.55, y: half * 0.6))
            path.addCurve(to: CGPoint(x: 0, y: -half), control1: CGPoint(x: -half * 0.55, y: half * 0.6),
                          control2: CGPoint(x: -half * 0.95, y: -half * 0.35))
        }
        context.addPath(path)
        context.setFillColor(color.nsColor(alpha: 1).cgColor)
        context.fillPath()
        context.setStrokeColor(vein.nsColor(alpha: 0.8).cgColor)
        context.setLineCap(.round)
        context.setLineWidth(max(0.6, size * 0.035))
        context.move(to: CGPoint(x: 0, y: half))
        context.addLine(to: CGPoint(x: 0, y: maple ? -half * 0.85 : -half * 0.8))
        if maple {
            for a in [-0.95, 0.95, -0.25, 0.25] as [CGFloat] {
                context.move(to: CGPoint(x: 0, y: half * 0.1))
                context.addLine(to: CGPoint(x: sin(a) * half * 0.75, y: -cos(a) * half * 0.6))
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func leafPile(_ size: CGSize, scale: CGFloat, light: Double) -> CGImage? {
        guard let context = canvas(size, scale: scale) else { return nil }
        var random = SeededRandom(0x5EA5_0A)
        let count = Int(size.width / 5)
        for index in 0..<count {
            // Гуще у самого края, реже кверху.
            let y = size.height - pow(random.next(), 1.8) * size.height * 0.8
            let side = 12 + random.next() * 12
            let color = tone(RGB.mix(autumnColors[index % autumnColors.count], RGB(0.45, 0.28, 0.12), random.next() * 0.35), light)
            drawLeaf(context, center: CGPoint(x: random.next() * size.width, y: y), size: side,
                     angle: random.next() * .pi * 2, color: color, maple: index % 4 == 0)
        }
        return context.makeImage()
    }

    // MARK: - Зима

    /// Замёрзшее стекло: белёсая кромка по краям и ветвистые узоры инея,
    /// растущие от рамы внутрь; поверх — редкие искры, которые мерцают.
    private func addWinter(size: CGSize, scale: CGFloat, light: Double, animated: Bool) {
        let frost = CALayer()
        frost.frame = CGRect(origin: .zero, size: size)
        frost.contents = Self.frostImage(size, scale: scale, light: light)
        frost.contentsScale = scale
        addSublayer(frost)

        let sparkles = CALayer()
        sparkles.frame = CGRect(origin: .zero, size: size)
        sparkles.contents = Self.sparkleImage(size, scale: scale)
        sparkles.contentsScale = scale
        sparkles.opacity = Float(0.4 + 0.6 * light)
        addSublayer(sparkles)
        guard animated else { return }
        let twinkle = CABasicAnimation(keyPath: "opacity")
        twinkle.fromValue = sparkles.opacity
        twinkle.toValue = sparkles.opacity * 0.2
        twinkle.duration = 3.2
        twinkle.autoreverses = true
        twinkle.repeatCount = .infinity
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        twinkle.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 8)
        sparkles.add(twinkle, forKey: "twinkle")
    }

    private static func frostImage(_ size: CGSize, scale: CGFloat, light: Double) -> CGImage? {
        guard let context = canvas(size, scale: scale) else { return nil }
        let ice = RGB.mix(RGB(0.62, 0.72, 0.86), RGB(0.97, 0.99, 1), light)
        let depth = min(size.width, size.height) * 0.16
        let space = CGColorSpace(name: CGColorSpace.sRGB)

        // Кромка: от каждого края внутрь, в углах — гуще. Ночью — слабее:
        // светлая муть на тёмном окне съедала бы панели.
        let strength = 0.35 + 0.65 * (light - 0.35) / 0.65
        if let edge = CGGradient(colorsSpace: space, colors: [ice.nsColor(alpha: 0.18 + 0.24 * strength).cgColor, ice.nsColor(alpha: 0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            let sides: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: depth)),
                (CGPoint(x: 0, y: size.height), CGPoint(x: 0, y: size.height - depth)),
                (CGPoint(x: 0, y: 0), CGPoint(x: depth, y: 0)),
                (CGPoint(x: size.width, y: 0), CGPoint(x: size.width - depth, y: 0)),
            ]
            for (from, to) in sides { context.drawLinearGradient(edge, start: from, end: to, options: []) }
            for corner in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height),
                           CGPoint(x: size.width, y: size.height)] {
                context.drawRadialGradient(edge, startCenter: corner, startRadius: 0, endCenter: corner,
                                           endRadius: depth * 1.7, options: [])
            }
        }

        // Узоры: от рамы внутрь, ветка за веткой под углом 60°, как растёт
        // кристалл. У углов — длиннее и гуще.
        var random = SeededRandom(0xF205_7)
        context.setLineCap(.round)
        func branch(_ start: CGPoint, _ angle: CGFloat, _ length: CGFloat, _ level: Int) {
            let segments = 5
            var point = start
            var heading = angle
            let step = length / CGFloat(segments)
            for index in 0..<segments {
                heading += (CGFloat(random.next()) - 0.5) * 0.22
                let next = CGPoint(x: point.x + cos(heading) * step, y: point.y + sin(heading) * step)
                context.setStrokeColor(ice.nsColor(alpha: (0.62 - Double(level) * 0.12) * (0.55 + 0.45 * strength)).cgColor)
                context.setLineWidth(max(0.5, 1.5 - CGFloat(level) * 0.35))
                context.move(to: point)
                context.addLine(to: next)
                context.strokePath()
                if level < 3, index < segments - 1 {
                    let child = length * (0.42 - CGFloat(level) * 0.06) * CGFloat(0.7 + random.next() * 0.5)
                    for side in [-1.0, 1.0] where random.next() < 0.85 {
                        branch(next, heading + CGFloat(side) * .pi / 3, child * CGFloat(1 - Double(index) * 0.12), level + 1)
                    }
                }
                point = next
            }
        }
        let perimeter = 2 * (size.width + size.height)
        let count = Int(perimeter / 46)
        for _ in 0..<count {
            // Точка на раме: тяготеет к углам.
            let t = random.next()
            let toCorner = t < 0.5 ? pow(t * 2, 1.6) / 2 : 1 - pow((1 - t) * 2, 1.6) / 2
            let side = Int(random.next() * 4)
            let start: CGPoint
            let inward: CGFloat
            switch side {
            case 0: start = CGPoint(x: toCorner * size.width, y: 0); inward = .pi / 2
            case 1: start = CGPoint(x: toCorner * size.width, y: size.height); inward = -.pi / 2
            case 2: start = CGPoint(x: 0, y: toCorner * size.height); inward = 0
            default: start = CGPoint(x: size.width, y: toCorner * size.height); inward = .pi
            }
            let cornerness = abs(toCorner - 0.5) * 2
            let length = depth * CGFloat(0.35 + random.next() * 0.6 + cornerness * 0.9)
            branch(start, inward + (CGFloat(random.next()) - 0.5) * 1.1, length, 0)
        }
        return context.makeImage()
    }

    private static func sparkleImage(_ size: CGSize, scale: CGFloat) -> CGImage? {
        guard let context = canvas(size, scale: scale) else { return nil }
        var random = SeededRandom(0x5_9A2C)
        let depth = min(size.width, size.height) * 0.22
        let count = Int(2 * (size.width + size.height) / 22)
        context.setFillColor(NSColor(white: 1, alpha: 0.95).cgColor)
        for _ in 0..<count {
            // У рамы: на расстоянии до `depth` от ближнего края.
            let inset = pow(random.next(), 1.5) * depth
            let along = random.next()
            let point: CGPoint = switch Int(random.next() * 4) {
            case 0: CGPoint(x: along * size.width, y: inset)
            case 1: CGPoint(x: along * size.width, y: size.height - inset)
            case 2: CGPoint(x: inset, y: along * size.height)
            default: CGPoint(x: size.width - inset, y: along * size.height)
            }
            let radius = 0.6 + random.next() * 0.9
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        return context.makeImage()
    }

    // MARK: - Весна

    private static let blossomColors = [RGB(1, 0.76, 0.84), RGB(1, 0.93, 0.95), RGB(0.97, 0.6, 0.74), RGB(1, 0.84, 0.9)]

    /// Цветущие деревья в нижних углах и лепестки, которые несёт ветер.
    private func addSpring(size: CGSize, scale: CGFloat, light: Double, animated: Bool) {
        let treeSize = CGSize(width: min(size.width * 0.32, 480), height: min(size.height * 0.58, 520))
        for (index, mirrored) in [false, true].enumerated() {
            let tree = CALayer()
            tree.frame = CGRect(x: mirrored ? size.width - treeSize.width : 0, y: size.height - treeSize.height,
                                width: treeSize.width, height: treeSize.height)
            tree.contents = Self.treeImage(treeSize, scale: scale, light: light, seed: UInt64(index + 3))
            tree.contentsScale = scale
            if mirrored { tree.transform = CATransform3DMakeScale(-1, 1, 1) }
            addSublayer(tree)
        }
        var random = SeededRandom(0x9E7A1)
        let count = max(14, min(30, Int(size.width / 65)))
        for index in 0..<count {
            let side = 11 + random.next() * 9
            let petal = CALayer()
            petal.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            petal.contentsScale = scale
            petal.contents = Self.petalImage(side: side, scale: scale,
                                             color: Self.tone(Self.blossomColors[index % Self.blossomColors.count], light))
            petal.opacity = 0.9
            addFalling(petal, size: size, random: &random, animated: animated, duration: 22...36, sway: 30...80)
        }
    }

    private static func petalImage(side: CGFloat, scale: CGFloat, color: RGB) -> CGImage? {
        guard let context = canvas(CGSize(width: side, height: side), scale: scale) else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: side / 2, y: side * 0.08))
        path.addCurve(to: CGPoint(x: side / 2, y: side * 0.92), control1: CGPoint(x: side * 1.02, y: side * 0.25),
                      control2: CGPoint(x: side * 0.8, y: side * 0.85))
        path.addCurve(to: CGPoint(x: side / 2, y: side * 0.08), control1: CGPoint(x: side * 0.2, y: side * 0.85),
                      control2: CGPoint(x: -side * 0.02, y: side * 0.25))
        context.addPath(path)
        context.setFillColor(color.nsColor(alpha: 1).cgColor)
        context.fillPath()
        return context.makeImage()
    }

    /// Дерево растёт из нижнего левого угла и клонится внутрь окна; ветки
    /// делятся до тонких, на концах — облака цвета. Ствол тёмный, цвет —
    /// розовый и белый, как у сакуры и яблони.
    private static func treeImage(_ size: CGSize, scale: CGFloat, light: Double, seed: UInt64) -> CGImage? {
        guard let context = canvas(size, scale: scale) else { return nil }
        var random = SeededRandom(seed &* 0x2545_F491)
        let bark = tone(RGB(0.32, 0.22, 0.2), light)
        var tips: [CGPoint] = []
        context.setLineCap(.round)
        context.setStrokeColor(bark.nsColor(alpha: 1).cgColor)
        func grow(_ start: CGPoint, _ angle: CGFloat, _ length: CGFloat, _ width: CGFloat, _ level: Int) {
            let bend = (CGFloat(random.next()) - 0.5) * 0.3
            let end = CGPoint(x: start.x + cos(angle + bend) * length, y: start.y + sin(angle + bend) * length)
            let control = CGPoint(x: (start.x + end.x) / 2 + cos(angle + .pi / 2) * length * 0.08,
                                  y: (start.y + end.y) / 2 + sin(angle + .pi / 2) * length * 0.08)
            context.setLineWidth(width)
            context.move(to: start)
            context.addQuadCurve(to: end, control: control)
            context.strokePath()
            if level >= 6 || length < 10 {
                tips.append(end)
                return
            }
            if level >= 3 { tips.append(CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)) }
            let children = random.next() < 0.35 ? 3 : 2
            for child in 0..<children {
                let spread = CGFloat(0.32 + random.next() * 0.35)
                let side: CGFloat = children == 2 ? (child == 0 ? -1 : 1) : CGFloat(child - 1)
                grow(end, angle + side * spread + (CGFloat(random.next()) - 0.5) * 0.15,
                     length * CGFloat(0.7 + random.next() * 0.12), width * 0.66, level + 1)
            }
        }
        // Ствол — у левого края, клонится вправо (внутрь окна).
        let base = CGPoint(x: size.width * 0.16, y: size.height + 4)
        grow(base, -.pi / 2 + 0.28, size.height * 0.26, max(10, size.width * 0.045), 0)

        for tip in tips {
            let clusters = 5 + Int(random.next() * 6)
            for _ in 0..<clusters {
                let radius = 2.5 + random.next() * 5
                let point = CGPoint(x: tip.x + (CGFloat(random.next()) - 0.5) * 26, y: tip.y + (CGFloat(random.next()) - 0.5) * 22)
                let color = tone(blossomColors[Int(random.next() * Double(blossomColors.count)) % blossomColors.count], light)
                context.setFillColor(color.nsColor(alpha: 0.88).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return context.makeImage()
    }

    // MARK: - Лето

    /// Луг вдоль нижнего края: дальняя полоса темнее и ниже, ближняя —
    /// с крупными цветами. Обе колышет ветер — каждую в своём ритме.
    private func addSummer(size: CGSize, scale: CGFloat, light: Double, animated: Bool) {
        let height = min(max(size.height * 0.16, 90), 160)
        for (index, front) in [false, true].enumerated() {
            let stripHeight = front ? height : height * 0.82
            let strip = CALayer()
            strip.anchorPoint = CGPoint(x: 0.5, y: 1)
            strip.bounds = CGRect(x: 0, y: 0, width: size.width + 40, height: stripHeight)
            strip.position = CGPoint(x: size.width / 2, y: size.height + 2)
            strip.contents = Self.meadowImage(strip.bounds.size, scale: scale, light: light * (front ? 1 : 0.85),
                                              front: front, seed: UInt64(index + 11))
            strip.contentsScale = scale
            addSublayer(strip)
            guard animated else { continue }
            // Ветер — сдвигом верха полосы, низ стоит на месте.
            var left = CATransform3DIdentity
            left.m21 = front ? -0.05 : -0.035
            var right = CATransform3DIdentity
            right.m21 = front ? 0.035 : 0.025
            let wind = CABasicAnimation(keyPath: "transform")
            wind.fromValue = NSValue(caTransform3D: left)
            wind.toValue = NSValue(caTransform3D: right)
            wind.duration = front ? 3.6 : 4.8
            wind.autoreverses = true
            wind.repeatCount = .infinity
            wind.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wind.preferredFrameRateRange = CAFrameRateRange(minimum: 6, maximum: 12, preferred: 10)
            strip.add(wind, forKey: "wind")
        }
    }

    private enum Flower: CaseIterable { case daisy, poppy, cornflower, buttercup, lavender }

    private static func meadowImage(_ size: CGSize, scale: CGFloat, light: Double, front: Bool, seed: UInt64) -> CGImage? {
        guard let context = canvas(size, scale: scale) else { return nil }
        var random = SeededRandom(seed &* 0x9E37_79B9)
        let greens = [RGB(0.3, 0.58, 0.22), RGB(0.42, 0.68, 0.26), RGB(0.24, 0.48, 0.2), RGB(0.5, 0.72, 0.3)]

        // Трава — тонкие изогнутые листья от нижнего края.
        let blades = Int(size.width / (front ? 2.2 : 1.8))
        for _ in 0..<blades {
            let x = random.next() * size.width
            let height = size.height * (0.3 + random.next() * 0.55) * (front ? 0.85 : 1)
            let lean = (CGFloat(random.next()) - 0.5) * 22
            let width = 1.6 + random.next() * 2.2
            let color = tone(greens[Int(random.next() * Double(greens.count)) % greens.count], light)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - width, y: size.height))
            path.addQuadCurve(to: CGPoint(x: x + lean, y: size.height - height), control: CGPoint(x: x - width * 0.3, y: size.height - height * 0.6))
            path.addQuadCurve(to: CGPoint(x: x + width, y: size.height), control: CGPoint(x: x + width * 0.6, y: size.height - height * 0.6))
            context.addPath(path)
            context.setFillColor(color.nsColor(alpha: 0.95).cgColor)
            context.fillPath()
        }

        // Цветы на стеблях.
        let flowers = Int(size.width / (front ? 24 : 34))
        context.setLineCap(.round)
        for _ in 0..<flowers {
            let x = random.next() * size.width
            let head = CGPoint(x: x + (CGFloat(random.next()) - 0.5) * 10,
                               y: size.height - size.height * (0.4 + random.next() * 0.5))
            let stem = tone(RGB(0.28, 0.52, 0.2), light)
            context.setStrokeColor(stem.nsColor(alpha: 1).cgColor)
            context.setLineWidth(1.2)
            context.move(to: CGPoint(x: x, y: size.height))
            context.addQuadCurve(to: head, control: CGPoint(x: x, y: (size.height + head.y) / 2))
            context.strokePath()
            let scaleFactor = CGFloat(front ? 1 : 0.75) * CGFloat(0.8 + random.next() * 0.5)
            drawFlower(context, Flower.allCases[Int(random.next() * Double(Flower.allCases.count)) % Flower.allCases.count],
                       at: head, size: scaleFactor, light: light)
        }
        return context.makeImage()
    }

    private static func drawFlower(_ context: CGContext, _ kind: Flower, at point: CGPoint, size: CGFloat, light: Double) {
        func dot(_ center: CGPoint, _ radius: CGFloat, _ color: RGB, _ alpha: Double = 1) {
            context.setFillColor(tone(color, light).nsColor(alpha: alpha).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        switch kind {
        case .daisy:
            for index in 0..<10 {
                let a = CGFloat(index) / 10 * .pi * 2
                context.saveGState()
                context.translateBy(x: point.x, y: point.y)
                context.rotate(by: a)
                context.setFillColor(tone(RGB(1, 1, 0.98), light).nsColor(alpha: 1).cgColor)
                context.fillEllipse(in: CGRect(x: 1.5 * size, y: -1.4 * size, width: 5.5 * size, height: 2.8 * size))
                context.restoreGState()
            }
            dot(point, 2.6 * size, RGB(0.98, 0.78, 0.15))
        case .poppy:
            for index in 0..<5 {
                let a = CGFloat(index) / 5 * .pi * 2
                dot(CGPoint(x: point.x + cos(a) * 3 * size, y: point.y + sin(a) * 3 * size), 4.2 * size, RGB(0.88, 0.14, 0.1), 0.95)
            }
            dot(point, 2 * size, RGB(0.15, 0.1, 0.1))
        case .cornflower:
            for index in 0..<8 {
                let a = CGFloat(index) / 8 * .pi * 2
                dot(CGPoint(x: point.x + cos(a) * 3.4 * size, y: point.y + sin(a) * 3.4 * size), 2.2 * size, RGB(0.28, 0.45, 0.92))
            }
            dot(point, 2 * size, RGB(0.2, 0.25, 0.6))
        case .buttercup:
            for index in 0..<5 {
                let a = CGFloat(index) / 5 * .pi * 2 - .pi / 2
                dot(CGPoint(x: point.x + cos(a) * 2.4 * size, y: point.y + sin(a) * 2.4 * size), 2.6 * size, RGB(1, 0.84, 0.1))
            }
            dot(point, 1.4 * size, RGB(0.95, 0.65, 0.05))
        case .lavender:
            for index in 0..<7 {
                let y = point.y + CGFloat(index) * 2.6 * size
                dot(CGPoint(x: point.x - 1.2 * size, y: y), 1.6 * size, RGB(0.6, 0.45, 0.85))
                dot(CGPoint(x: point.x + 1.2 * size, y: y + 1.2 * size), 1.6 * size, RGB(0.52, 0.38, 0.8))
            }
        }
    }
}

extension SkyScene.Season {
    var title: String {
        switch self {
        case .winter: String(localized: "Зима")
        case .spring: String(localized: "Весна")
        case .summer: String(localized: "Лето")
        case .autumn: String(localized: "Осень")
        }
    }
}
