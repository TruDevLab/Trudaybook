import Foundation

/// Шкала дня: перевод времени в координату и обратно.
public struct TimelineScale: Hashable, Sendable {
    public var dayStart: Date
    /// Ширина одного часа в точках — это и есть масштаб.
    public var hourWidth: Double
    public var hours: Double

    public init(dayStart: Date, hourWidth: Double, hours: Double = 24) {
        self.dayStart = dayStart
        self.hourWidth = hourWidth
        self.hours = hours
    }

    public var totalWidth: Double { hours * hourWidth }

    public func x(for date: Date) -> Double {
        date.timeIntervalSince(dayStart) / 3600 * hourWidth
    }

    public func date(at x: Double) -> Date {
        dayStart.addingTimeInterval(x / hourWidth * 3600)
    }

    public static let minHourWidth: Double = 48
    public static let maxHourWidth: Double = 480

    public static func clampHourWidth(_ value: Double) -> Double {
        min(max(value, minHourWidth), maxHourWidth)
    }
}

/// Как показать точечные элементы (письма, напоминания) одной дорожки.
public enum PointGroup: Hashable, Sendable {
    /// Одна карточка на своём месте.
    case single(id: String, x: Double)
    /// Пачка «+N»: элементов рядом так много, что карточками они не помещаются.
    case cluster(ids: [String], x: Double, width: Double)

    public var x: Double {
        switch self {
        case .single(_, let x), .cluster(_, let x, _): return x
        }
    }

    public var ids: [String] {
        switch self {
        case .single(let id, _): return [id]
        case .cluster(let ids, _, _): return ids
        }
    }
}

/// Размещение встречи на дорожке: по горизонтали — время, по вертикали —
/// ряд внутри группы пересекающихся встреч.
public struct IntervalPlacement: Hashable, Sendable {
    public var id: String
    public var x: Double
    public var width: Double
    public var row: Int
    /// Сколько рядов у группы пересекающихся встреч, в которую входит эта.
    public var rows: Int
}

public enum TimelineLayout {
    public struct Point: Hashable, Sendable {
        public var id: String
        public var x: Double

        public init(id: String, x: Double) {
            self.id = id
            self.x = x
        }
    }

    public struct Interval: Hashable, Sendable {
        public var id: String
        public var start: Double
        public var end: Double

        public init(id: String, start: Double, end: Double) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// Раскладывает точечные элементы дорожки.
    ///
    /// Близкие по времени карточки встают бок о бок, начиная с места первой,
    /// — сдвиг вправо не больше нескольких карточек. Если рядом оказывается
    /// больше `maxSideBySide`, группа сворачивается в пачку фиксированной
    /// ширины. Ширина пачки фиксирована нарочно: иначе при плотном потоке
    /// писем группа тянулась бы цепочкой через весь день.
    public static func groupPoints(
        _ points: [Point],
        cardWidth: Double,
        gap: Double,
        maxSideBySide: Int,
        clusterWidth: Double
    ) -> [PointGroup] {
        let sorted = points.sorted { ($0.x, $0.id) < ($1.x, $1.id) }

        func width(of count: Int) -> Double {
            count <= maxSideBySide
                ? Double(count) * cardWidth + Double(max(count - 1, 0)) * gap
                : clusterWidth
        }

        var groups: [(start: Double, ids: [String])] = []
        for point in sorted {
            if var last = groups.last, point.x < last.start + width(of: last.ids.count) + gap {
                last.ids.append(point.id)
                groups[groups.count - 1] = last
            } else {
                groups.append((point.x, [point.id]))
            }
        }

        return groups.flatMap { group -> [PointGroup] in
            if group.ids.count > maxSideBySide {
                return [.cluster(ids: group.ids, x: group.start, width: clusterWidth)]
            }
            return group.ids.enumerated().map { index, id in
                .single(id: id, x: group.start + Double(index) * (cardWidth + gap))
            }
        }
    }

    /// Раскладывает встречи по рядам.
    ///
    /// Пересекающиеся встречи делят высоту дорожки: каждая получает свой ряд,
    /// а число рядов считается для группы, связанной пересечениями, — так
    /// одиночная встреча занимает всю высоту, а не треть из-за чужой группы.
    /// Короткая встреча считается шириной не меньше `minWidth`: иначе её
    /// подпись налезала бы на соседнюю, хотя по времени они не пересекаются.
    public static func placeIntervals(_ intervals: [Interval], minWidth: Double) -> [IntervalPlacement] {
        let sorted = intervals.sorted {
            ($0.start, -($0.end - $0.start), $0.id) < ($1.start, -($1.end - $1.start), $1.id)
        }

        var result: [IntervalPlacement] = []
        var group: [IntervalPlacement] = []
        var rowEnds: [Double] = []
        var groupEnd = -Double.infinity

        func flush() {
            let rows = max(rowEnds.count, 1)
            for var placement in group {
                placement.rows = rows
                result.append(placement)
            }
            group = []
            rowEnds = []
            groupEnd = -Double.infinity
        }

        for interval in sorted {
            let width = max(interval.end - interval.start, minWidth)
            let visualEnd = interval.start + width

            if interval.start >= groupEnd { flush() }

            let row: Int
            if let free = rowEnds.firstIndex(where: { $0 <= interval.start }) {
                row = free
                rowEnds[free] = visualEnd
            } else {
                row = rowEnds.count
                rowEnds.append(visualEnd)
            }
            groupEnd = max(groupEnd, visualEnd)
            group.append(IntervalPlacement(id: interval.id, x: interval.start, width: width, row: row, rows: 1))
        }
        flush()
        return result
    }
}
