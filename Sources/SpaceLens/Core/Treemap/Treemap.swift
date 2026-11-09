import Foundation

public struct TreemapRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

public struct TreemapCell<ID: Hashable>: Sendable where ID: Sendable {
    public var id: ID
    public var rect: TreemapRect
}

/// Squarified treemap (Bruls, Huizing, van Wijk): cells keep an aspect ratio close to 1 so small items stay
/// visible, and the cells tile the rectangle exactly, in the order of decreasing weight.
public enum Treemap {
    public static func layout<ID: Hashable & Sendable>(
        _ items: [(id: ID, weight: Double)], in bounds: TreemapRect
    ) -> [TreemapCell<ID>] {
        let positive = items.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        let total = positive.reduce(0) { $0 + $1.weight }
        guard total > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let scale = bounds.area / total
        let areas = positive.map { (id: $0.id, area: $0.weight * scale) }

        var cells: [TreemapCell<ID>] = []
        var free = bounds
        var index = 0
        while index < areas.count {
            let side = min(free.width, free.height)
            var row: [(id: ID, area: Double)] = [areas[index]]
            var worst = worstRatio(row.map(\.area), side)
            var next = index + 1
            while next < areas.count {
                let candidate = row + [areas[next]]
                let candidateWorst = worstRatio(candidate.map(\.area), side)
                if candidateWorst > worst { break }
                row = candidate
                worst = candidateWorst
                next += 1
            }
            free = place(row, in: free, into: &cells)
            index = next
        }
        return cells
    }

    private static func worstRatio(_ areas: [Double], _ side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard let maxArea = areas.max(), let minArea = areas.min(), sum > 0, side > 0 else { return .infinity }
        let s2 = side * side
        return max(s2 * maxArea / (sum * sum), (sum * sum) / (s2 * minArea))
    }

    /// Lays one row along the shorter side and returns what is left of the rectangle.
    private static func place<ID: Hashable & Sendable>(
        _ row: [(id: ID, area: Double)], in free: TreemapRect, into cells: inout [TreemapCell<ID>]
    ) -> TreemapRect {
        let sum = row.reduce(0) { $0 + $1.area }
        if free.width >= free.height {
            let rowWidth = sum / free.height
            var y = free.y
            for entry in row {
                let h = entry.area / rowWidth
                cells.append(TreemapCell(id: entry.id, rect: TreemapRect(x: free.x, y: y, width: rowWidth, height: h)))
                y += h
            }
            return TreemapRect(x: free.x + rowWidth, y: free.y, width: free.width - rowWidth, height: free.height)
        } else {
            let rowHeight = sum / free.width
            var x = free.x
            for entry in row {
                let w = entry.area / rowHeight
                cells.append(TreemapCell(id: entry.id, rect: TreemapRect(x: x, y: free.y, width: w, height: rowHeight)))
                x += w
            }
            return TreemapRect(x: free.x, y: free.y + rowHeight, width: free.width, height: free.height - rowHeight)
        }
    }
}
