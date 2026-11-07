import AppKit

/// 容器注册表，以及创建、插入、恢复等编排逻辑。
@MainActor
final class ContainerManager {
    private let tracker: WindowTracker
    weak var groups: GroupManager?

    private(set) var containers: [CGWindowID: Container] = [:]
    private(set) var childMap: [CGWindowID: Container] = [:]

    private static let savedKey = "savedContainers"

    init(tracker: WindowTracker) {
        self.tracker = tracker
    }

    // MARK: Lookups

    subscript(id: CGWindowID) -> Container? { containers[id] }

    func container(forChild id: CGWindowID) -> Container? { childMap[id] }
    func container(forTab id: CGWindowID) -> Container? { containers[id] }
    func isChild(_ id: CGWindowID) -> Bool { childMap[id] != nil }
    func isContainer(_ id: CGWindowID) -> Bool { containers[id] != nil }

    /// 当前激活的容器中，指针下的容器和具体子窗口。
    /// 用 WindowServer 的真实 Z 序判断：如果指针下最上面的是别的 App 的普通窗口，
    /// 就不要误命中它后面的容器。
    func target(at p: CGPoint, excluding: Set<CGWindowID>) -> (Container, CGWindowID?)? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(p) else { continue }
            let id = CGWindowID(number)
            if excluding.contains(id) { continue }
            if (info[kCGWindowOwnerPID as String] as? Int32) == getpid() {
                // 我们自己的容器壳。
                if let c = containers[id] { return (c, nil) }
                let own = NSApp.window(withWindowNumber: Int(id))
                // 分割线、拖放高亮、阴影都是覆盖层：继续看它们下面的窗口。
                if own is SplitterPanel || own is ContainerResizePanel { continue }
                if let own, own.ignoresMouseEvents { continue }
                // 标签条、设置窗口等：不是容器目标。
                if own != nil { return nil }
                continue
            }
            // 最上面的真实窗口要么是某个容器的子窗口，要么不是容器目标。
            if let c = childMap[id] { return (c, id) }
            return nil
        }
        // 指针下没有别的 App 窗口：说明命中的是我们自己的容器壳或分割线。
        for c in containers.values where c.isActive && c.frame.contains(p) {
            return (c, nil)
        }
        return nil
    }

    // MARK: Create / insert

    @discardableResult
    func create(from source: Win, and target: Win, at point: CGPoint?, sourceFrame: CGRect? = nil) -> Container? {
        guard source.id != target.id, childMap[source.id] == nil, childMap[target.id] == nil,
              let targetFrame = target.frame, targetFrame.width > 100, targetFrame.height > 80 else { return nil }

        // 如果它们原本是 TabGroups 的 tab，先从原分组中摘出来，避免同一个窗口被两处管理。
        groups?.detachForContainer(source.id)
        groups?.detachForContainer(target.id)

        let container = Container(frame: targetFrame, firstChild: target)
        // A/B merge follows the display orientation: top/bottom on a portrait
        // screen, left/right on a landscape screen.
        let screenFrame = Coords.screenFrame(containing: targetFrame)
        let portrait = screenFrame.height > screenFrame.width
        let initialAxis: SplitAxis = portrait ? .horizontal : .vertical
        let preferFirst = point.map { p in
            initialAxis == .vertical ? p.x <= targetFrame.midX : p.y <= targetFrame.midY
        } ?? true
        _ = container.insert(source, targetChild: target.id, at: point,
                             preferFirst: preferFirst, axisOverride: initialAxis)
        if let sourceFrame { container.setPreFrame(source.id, sourceFrame) }
        register(container)
        // A new workspace starts standalone; no TabGroups strip until the
        // user explicitly groups another window with it.
        container.activate()
        return container
    }

    @discardableResult
    func insert(_ source: Win, into container: Container, targetChild: CGWindowID?,
                at point: CGPoint?, sourceFrame: CGRect? = nil) -> Bool {
        guard containers[container.anchorID] === container,
              container.count < Container.maxChildren, container.children[source.id] == nil else { return false }

        var originalPre: CGRect?
        if let old = childMap[source.id] {
            originalPre = old.preFrames[source.id]
            old.removeChild(source.id, restoreFrame: false)
            childMap[source.id] = nil
        }
        groups?.detachForContainer(source.id)

        guard container.insert(source, targetChild: targetChild, at: point) else { return false }
        if let originalPre {
            container.setPreFrame(source.id, originalPre)
        } else if let sourceFrame {
            container.setPreFrame(source.id, sourceFrame)
        }
        childMap[source.id] = container
        groups?.containerNeedsTabRefresh(container)
        container.activate()
        return true
    }

    private func register(_ container: Container) {
        let id = container.anchorID
        containers[id] = container
        container.delegate = groups
        for child in container.children.keys { childMap[child] = container }
    }

    func unregister(_ container: Container) {
        containers[container.anchorID] = nil
        for child in container.children.keys { childMap[child] = nil }
    }

    // MARK: Child events

    func handle(_ w: Win, _ event: ChildEvent) -> Bool {
        guard let c = childMap[w.id] else { return false }
        _ = c.handleChildEvent(w, event)
        if c.children[w.id] == nil { childMap[w.id] = nil }
        return true
    }

    /// A child window went away without a destroy notification (apps that
    /// only hide their window on close). Remove it so its pane collapses.
    func removeChild(_ id: CGWindowID) {
        guard let c = childMap[id] else { return }
        c.removeChild(id, restoreFrame: false)
        childMap[id] = nil
    }

    // MARK: Teardown

    func discard(_ container: Container) {
        unregister(container)
        container.releaseChildren()
    }

    func releaseAll() {
        for c in Array(containers.values) {
            unregister(c)
            c.releaseChildren()
        }
        containers.removeAll()
        childMap.removeAll()
    }

    // MARK: Persistence

    struct SavedChild: Codable {
        var id: CGWindowID
        var bundleID: String?
        var title: String
        var preFrame: CGRect
    }

    struct SavedContainer: Codable {
        var id: UUID
        var frame: CGRect
        var activeChild: CGWindowID?
        var node: LayoutNode?
        var children: [SavedChild]
        var order: [CGWindowID]? = nil
        var customTitle: String? = nil
    }

    func save() {
        let saved = containers.values.compactMap { c -> SavedContainer? in
            guard !c.children.isEmpty, let node = c.node else { return nil }
            return SavedContainer(
                id: c.uuid,
                frame: c.frame,
                activeChild: c.activeChild,
                node: node,
                children: c.children.compactMap { id, w in
                    guard let pre = c.preFrames[id] else { return nil }
                    return SavedChild(id: id, bundleID: w.bundleID, title: w.title, preFrame: pre)
                },
                order: c.order,
                customTitle: c.customTitle
            )
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.savedKey)
    }

    /// 启动时重建容器壳；子窗口能匹配到就挂上，匹配不到的叶子会被剪掉。
    func restore() -> [UUID: Container] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode([SavedContainer].self, from: data) else { return [:] }
        UserDefaults.standard.removeObject(forKey: Self.savedKey)

        var used = Set<CGWindowID>()
        var out: [UUID: Container] = [:]

        func bundle(_ w: Win) -> String? {
            NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier
        }

        for s in saved {
            var matched: [Win] = []
            var preFrames: [CGWindowID: CGRect] = [:]
            for child in s.children {
                let candidate: Win?
                if let w = tracker.windows[child.id], !used.contains(w.id), bundle(w) == child.bundleID {
                    candidate = w
                } else {
                    let same = tracker.windows.values.filter {
                        !used.contains($0.id) && bundle($0) == child.bundleID && $0.title == child.title
                    }
                    candidate = same.count == 1 ? same[0] : nil
                }
                guard let w = candidate else { continue }
                used.insert(w.id)
                matched.append(w)
                preFrames[w.id] = child.preFrame
            }
            guard let first = matched.first else { continue }

            var tree = s.node
            for id in (tree?.leafIDs ?? []) where !matched.contains(where: { $0.id == id }) {
                tree = tree?.removing(id)
            }
            if tree == nil { tree = .leaf(first.id) }

            let c = Container(frame: s.frame, uuid: s.id, firstChild: first)
            c.restore(children: matched, node: tree, activeChild: s.activeChild,
                      preFrames: preFrames, order: s.order)
            register(c)
            c.setCustomTitle(s.customTitle)
            c.deactivate()
            out[s.id] = c
        }
        return out
    }
}
