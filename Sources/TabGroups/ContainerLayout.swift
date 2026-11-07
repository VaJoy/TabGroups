import AppKit

enum SplitAxis: String, Codable {
    /// 左右分隔，分界线是竖线。
    case vertical
    /// 上下分隔，分界线是横线。
    case horizontal
}

/// 一条可以拖动的内部分界线。
struct SplitterInfo {
    let id: UUID
    let axis: SplitAxis
    /// 这一级 split 的完整区域（AX 坐标）。
    let parent: CGRect
    /// 分界线所在的 gutter 区域（AX 坐标）。
    let band: CGRect
    let ratio: CGFloat
    /// 两侧最小可压缩长度，用来 clamp 比例。
    let firstMin: CGFloat
    let secondMin: CGFloat
}

/// 容器的布局模型：二叉分割树，叶子是最多 4 个窗口。
indirect enum LayoutNode: Codable {
    case leaf(CGWindowID)
    case split(id: UUID, axis: SplitAxis, ratio: CGFloat, first: LayoutNode, second: LayoutNode)

    var count: Int {
        switch self {
        case .leaf: 1
        case let .split(_, _, _, first, second): first.count + second.count
        }
    }

    var leafIDs: [CGWindowID] {
        switch self {
        case let .leaf(id): [id]
        case let .split(_, _, _, first, second): first.leafIDs + second.leafIDs
        }
    }

    func frames(in rect: CGRect, gutter: CGFloat) -> [CGWindowID: CGRect] {
        switch self {
        case let .leaf(id):
            return [id: rect]
        case let .split(_, axis, ratio, first, second):
            let pieces = Self.divide(rect, axis: axis, ratio: ratio, gutter: gutter)
            guard let pieces else { return [:] }
            var out = first.frames(in: pieces.0, gutter: gutter)
            out.merge(second.frames(in: pieces.1, gutter: gutter)) { $1 }
            return out
        }
    }

    func frame(of target: CGWindowID, in rect: CGRect, gutter: CGFloat) -> CGRect? {
        switch self {
        case let .leaf(id):
            return id == target ? rect : nil
        case let .split(_, axis, ratio, first, second):
            guard let pieces = Self.divide(rect, axis: axis, ratio: ratio, gutter: gutter) else { return nil }
            return first.frame(of: target, in: pieces.0, gutter: gutter)
                ?? second.frame(of: target, in: pieces.1, gutter: gutter)
        }
    }

    func splitters(in rect: CGRect, gutter: CGFloat, minSizes: [CGWindowID: CGSize]) -> [SplitterInfo] {
        switch self {
        case .leaf:
            return []
        case let .split(id, axis, ratio, first, second):
            guard let pieces = Self.divide(rect, axis: axis, ratio: ratio, gutter: gutter) else { return [] }
            let band: CGRect
            switch axis {
            case .vertical:
                band = CGRect(x: pieces.0.maxX, y: rect.minY, width: gutter, height: rect.height)
            case .horizontal:
                band = CGRect(x: rect.minX, y: pieces.0.maxY, width: rect.width, height: gutter)
            }
            let firstMin = first.requiredLength(axis: axis, minSizes: minSizes, gutter: gutter)
            let secondMin = second.requiredLength(axis: axis, minSizes: minSizes, gutter: gutter)
            var out = [SplitterInfo(id: id, axis: axis, parent: rect, band: band,
                                     ratio: ratio, firstMin: firstMin, secondMin: secondMin)]
            out += first.splitters(in: pieces.0, gutter: gutter, minSizes: minSizes)
            out += second.splitters(in: pieces.1, gutter: gutter, minSizes: minSizes)
            return out
        }
    }

    /// 沿某个轴，这个子树至少需要多长。
    func requiredLength(axis: SplitAxis, minSizes: [CGWindowID: CGSize], gutter: CGFloat) -> CGFloat {
        switch self {
        case let .leaf(id):
            let size = minSizes[id] ?? CGSize(width: 160, height: 100)
            return axis == .vertical ? size.width : size.height
        case let .split(_, splitAxis, _, first, second):
            if splitAxis == axis {
                return first.requiredLength(axis: axis, minSizes: minSizes, gutter: gutter)
                    + gutter
                    + second.requiredLength(axis: axis, minSizes: minSizes, gutter: gutter)
            }
            return max(first.requiredLength(axis: axis, minSizes: minSizes, gutter: gutter),
                       second.requiredLength(axis: axis, minSizes: minSizes, gutter: gutter))
        }
    }

    /// 面积最大的叶子；面积相同取树的顺序里更靠后的那个（右/下）。
    func largestLeaf(in rect: CGRect, gutter: CGFloat) -> (CGWindowID, CGRect)? {
        let frames = frames(in: rect, gutter: gutter)
        let indices = Dictionary(uniqueKeysWithValues: leafIDs.enumerated().map { ($0.element, $0.offset) })
        return frames.max { a, b in
            let areaA = a.value.width * a.value.height
            let areaB = b.value.width * b.value.height
            if abs(areaA - areaB) < 1 { return (indices[a.key] ?? 0) < (indices[b.key] ?? 0) }
            return areaA < areaB
        }.map { ($0.key, $0.value) }
    }

    /// 把 target 叶子替换成一个新的 split。
    func inserting(_ newID: CGWindowID, at target: CGWindowID, axis: SplitAxis,
                   newFirst: Bool, ratio: CGFloat = 0.5) -> LayoutNode {
        let split = LayoutNode.split(id: UUID(), axis: axis, ratio: ratio,
                                     first: .leaf(newFirst ? newID : target),
                                     second: .leaf(newFirst ? target : newID))
        return replacing(target, with: split)
    }

    func replacing(_ target: CGWindowID, with replacement: LayoutNode) -> LayoutNode {
        switch self {
        case let .leaf(id):
            return id == target ? replacement : self
        case let .split(id, axis, ratio, first, second):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: first.replacing(target, with: replacement),
                          second: second.replacing(target, with: replacement))
        }
    }

    /// 删除一个叶子；返回 nil 表示这个子树空了。只剩一个孩子时自动折叠到孩子。
    func removing(_ target: CGWindowID) -> LayoutNode? {
        switch self {
        case let .leaf(id):
            return id == target ? nil : self
        case let .split(id, axis, ratio, first, second):
            let a = first.removing(target)
            let b = second.removing(target)
            if a == nil { return b }
            if b == nil { return a }
            return .split(id: id, axis: axis, ratio: ratio, first: a!, second: b!)
        }
    }

    func updatingRatio(of target: UUID, to ratio: CGFloat) -> LayoutNode {
        switch self {
        case .leaf:
            return self
        case let .split(id, axis, current, first, second):
            if id == target {
                return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
            }
            return .split(id: id, axis: axis, ratio: current,
                          first: first.updatingRatio(of: target, to: ratio),
                          second: second.updatingRatio(of: target, to: ratio))
        }
    }

    private static func divide(_ rect: CGRect, axis: SplitAxis, ratio: CGFloat,
                               gutter: CGFloat) -> (CGRect, CGRect)? {
        let r = min(max(ratio, 0.05), 0.95)
        switch axis {
        case .vertical:
            let available = rect.width - gutter
            guard available > 1 else { return nil }
            let firstWidth = available * r
            let first = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let second = CGRect(x: rect.minX + firstWidth + gutter, y: rect.minY,
                                width: available - firstWidth, height: rect.height)
            return (first, second)
        case .horizontal:
            let available = rect.height - gutter
            guard available > 1 else { return nil }
            let firstHeight = available * r
            let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let second = CGRect(x: rect.minX, y: rect.minY + firstHeight + gutter,
                                width: rect.width, height: available - firstHeight)
            return (first, second)
        }
    }
}
