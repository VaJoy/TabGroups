import AppKit

@MainActor
protocol ContainerDelegate: AnyObject {
    func containerFrameChanged(_ container: Container)
    func containerInteractionEnded(_ container: Container)
    func containerNeedsTabRefresh(_ container: Container)
    func containerRequestedClose(_ container: Container)
    func containerDidBecomeEmpty(_ container: Container)
    /// The workspace header was dragged with the TabGroups drag key held.
    func container(_ container: Container, requestedGroupAt point: CGPoint)
    func containerZoomRequested(_ container: Container)
}

/// 一个“拼贴容器”：最多 4 个跨 App 窗口，按二叉分割树共享一个壳窗口。
@MainActor
final class Container: ContainerWindowEvents {
    static let maxChildren = 4
    static let gutter: CGFloat = 6

    let uuid: UUID
    let shell: ContainerWindow
    weak var delegate: ContainerDelegate?

    private(set) var children: [CGWindowID: Win] = [:]
    private(set) var node: LayoutNode?
    private(set) var order: [CGWindowID] = []
    private(set) var preFrames: [CGWindowID: CGRect] = [:]
    private(set) var activeChild: CGWindowID?
    private(set) var isActive = false
    private(set) var customTitle: String?
    /// 壳窗口的 frame（AX 坐标），也就是 TabGroups 里的 windowFrame。
    private(set) var frame: CGRect

    private var splitterPanels: [UUID: SplitterPanel] = [:]
    private var resizePanels: [ContainerResizeEdge: ContainerResizePanel] = [:]
    private enum PaneSide: Equatable {
        case left, right, top, bottom
    }
    private enum PaneCommit {
        case outer(ContainerResizeEdge)
        case splitter(PaneSide)
    }
    /// A child was seen off its pane (usually its own edge drag); commit its new
    /// edge after mouse-up instead of snapping, without fighting a drag.
    private var paneSettle: [CGWindowID: DispatchWorkItem] = [:]
    private var paneCommit: [CGWindowID: PaneCommit] = [:]
    /// Focus events caused by our own AX raises should not change the active
    /// pane or trigger another raise cycle.
    private var ignoreFocusUntil: Date?
    private var bringingForward = false
    private var applyingFrame = false

    var anchorID: CGWindowID { CGWindowID(shell.windowNumber) }
    var count: Int { children.count }
    var isEmpty: Bool { children.isEmpty }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return count == 0 ? "Empty Container" : "Workspace \(count)"
    }
    var icon: NSImage { Container.gridIcon }

    init(frame: CGRect, uuid: UUID = UUID(), firstChild: Win) {
        self.uuid = uuid
        self.frame = frame
        self.shell = ContainerWindow(frame: Coords.toAppKit(frame))
        self.children[firstChild.id] = firstChild
        self.order = [firstChild.id]
        self.activeChild = firstChild.id
        self.node = .leaf(firstChild.id)
        if let f = firstChild.frame { preFrames[firstChild.id] = f }
        shell.events = self
        shell.titleText = title
        shell.countText = "\(count)"
        shell.orderFrontRegardless()
        installResizePanels()
    }

    /// Thin handles over the left/right/bottom borders; the shell's own 6 px
    /// border is easy to miss, especially when a child reaches close to it.
    private func installResizePanels() {
        for edge in [ContainerResizeEdge.left, .right, .bottom] {
            let panel = ContainerResizePanel(
                edge: edge,
                onFrame: { [weak self] frame in self?.shell.setFrame(frame, display: true) },
                onEnd: { [weak self] in self?.resizeEnded() }
            )
            panel.shellWindow = shell
            resizePanels[edge] = panel
        }
    }

    func resizeEnded() {
        delegate?.containerInteractionEnded(self)
    }

    /// Commit an off-pane child's dragged edge after mouse-up: an outer edge
    /// resizes the shell, an inner edge updates the splitter ratio; a plain
    /// move or a top-edge resize snaps back.
    private func schedulePaneSettle(_ id: CGWindowID, commit: PaneCommit?) {
        paneSettle[id]?.cancel()
        paneCommit[id] = commit
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.paneSettle[id] = nil
                guard let w = self.children[id], let target = self.frame(of: id),
                      let current = w.frame, !current.equalTo(target) else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.schedulePaneSettle(id, commit: self.paneCommit[id])
                    return
                }
                if let commit = self.paneCommit[id] {
                    switch commit {
                    case let .outer(edge):
                        self.commitOuterResize(id, edge: edge)
                    case let .splitter(side):
                        if !self.commitSplitterResize(id, side: side) {
                            if target.width >= w.minSize.width, target.height >= w.minSize.height {
                                self.place(w, target)
                            }
                        }
                    }
                } else {
                    guard target.width >= w.minSize.width, target.height >= w.minSize.height else { return }
                    self.place(w, target)
                }
                self.paneCommit[id] = nil
            }
        }
        paneSettle[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Which outer/splitter edge the child is currently dragging, if any.
    private func paneCommitKind(for id: CGWindowID) -> PaneCommit? {
        guard let target = frame(of: id), let w = children[id], let current = w.frame,
              current.size != target.size else { return nil }
        let content = contentFrame
        let tolerance: CGFloat = 2
        let sides: [(PaneSide, CGFloat)] = [
            (.left, abs(current.minX - target.minX)),
            (.right, abs(current.maxX - target.maxX)),
            (.top, abs(current.minY - target.minY)),
            (.bottom, abs(current.maxY - target.maxY))
        ]
        guard let best = sides.max(by: { $0.1 < $1.1 }), best.1 > 1 else { return nil }
        switch best.0 {
        case .left:
            if abs(target.minX - content.minX) <= tolerance { return .outer(.left) }
            return splitterInfo(for: id, side: .left, target: target) != nil ? .splitter(.left) : nil
        case .right:
            if abs(target.maxX - content.maxX) <= tolerance { return .outer(.right) }
            return splitterInfo(for: id, side: .right, target: target) != nil ? .splitter(.right) : nil
        case .bottom:
            if abs(target.maxY - content.maxY) <= tolerance { return .outer(.bottom) }
            return splitterInfo(for: id, side: .bottom, target: target) != nil ? .splitter(.bottom) : nil
        case .top:
            // The workspace top is the header; only an internal top edge maps
            // to a horizontal splitter.
            if abs(target.minY - content.minY) <= tolerance { return nil }
            return splitterInfo(for: id, side: .top, target: target) != nil ? .splitter(.top) : nil
        }
    }

    private func splitterInfo(for id: CGWindowID, side: PaneSide, target: CGRect) -> SplitterInfo? {
        guard let node else { return nil }
        let infos = node.splitters(in: contentFrame, gutter: Self.gutter, minSizes: minSizes)
        let matches: [SplitterInfo]
        switch side {
        case .left:
            matches = infos.filter { $0.axis == .vertical && abs($0.band.maxX - target.minX) <= 1 }
        case .right:
            matches = infos.filter { $0.axis == .vertical && abs($0.band.minX - target.maxX) <= 1 }
        case .top:
            matches = infos.filter { $0.axis == .horizontal && abs($0.band.maxY - target.minY) <= 1 }
        case .bottom:
            matches = infos.filter { $0.axis == .horizontal && abs($0.band.minY - target.maxY) <= 1 }
        }
        return matches.min { a, b in
            a.parent.width * a.parent.height < b.parent.width * b.parent.height
        }
    }

    /// Update the splitter ratio so the pane's dragged inner edge becomes the
    /// new divider; the siblings and the rest of the tree re-layout.
    private func commitSplitterResize(_ id: CGWindowID, side: PaneSide) -> Bool {
        guard let w = children[id], let target = frame(of: id), let current = w.frame,
              current != target,
              target.width >= w.minSize.width, target.height >= w.minSize.height,
              let info = splitterInfo(for: id, side: side, target: target) else { return false }
        let gutter = Self.gutter
        let boundary: CGFloat
        switch side {
        case .right: boundary = current.maxX
        case .left: boundary = current.minX - gutter
        case .top: boundary = current.minY - gutter
        case .bottom: boundary = current.maxY
        }
        let available = info.axis == .vertical ? info.parent.width - gutter : info.parent.height - gutter
        guard available > 1 else { return false }
        let raw = (info.axis == .vertical ? boundary - info.parent.minX : boundary - info.parent.minY) / available
        let lower = max(0.15, info.firstMin / available)
        let upper = min(0.85, 1 - info.secondMin / available)
        guard lower <= upper else { return false }
        let ratio = min(max(raw, lower), upper)
        node = node?.updatingRatio(of: info.id, to: ratio)
        layout()
        return true
    }

    /// Grow/shrink the shell so the pane's dragged outer edge becomes the new
    /// workspace border; the other panes re-layout around it.
    private func commitOuterResize(_ id: CGWindowID, edge: ContainerResizeEdge) {
        guard let w = children[id], let target = frame(of: id), let current = w.frame,
              current != target,
              target.width >= w.minSize.width, target.height >= w.minSize.height else { return }
        var f = frame
        let pad = ContainerWindow.outerPadding
        let minW: CGFloat = 320
        let minH: CGFloat = 220
        switch edge {
        case .left:
            f.origin.x = current.minX - pad
            f.size.width = f.maxX - f.origin.x
            if f.width < minW {
                f.origin.x = f.maxX - minW
                f.size.width = minW
            }
        case .right:
            f.size.width = current.maxX + pad - f.minX
            if f.size.width < minW { f.size.width = minW }
        case .bottom:
            f.size.height = current.maxY + pad - f.minY
            if f.size.height < minH { f.size.height = minH }
        }
        guard f != frame else { return }
        shell.setFrame(Coords.toAppKit(f), display: true)
        resizeEnded()
    }

    /// 从保存的数据恢复子窗口和布局。
    func restore(children newChildren: [Win], node newNode: LayoutNode?,
                 activeChild newActive: CGWindowID?, preFrames newPreFrames: [CGWindowID: CGRect],
                 order newOrder: [CGWindowID]? = nil) {
        children = Dictionary(uniqueKeysWithValues: newChildren.map { ($0.id, $0) })
        let savedOrder = newOrder?.filter { children[$0] != nil } ?? []
        order = savedOrder.isEmpty ? newChildren.map(\.id) : savedOrder
        node = newNode
        activeChild = newActive.flatMap { children[$0] != nil ? $0 : nil } ?? order.first
        preFrames = newPreFrames
        for w in newChildren where preFrames[w.id] == nil {
            if let f = w.frame { preFrames[w.id] = f }
        }
        layout()
        updateHeader()
    }

    // MARK: Window events

    func containerWindowFrameChanged(_ window: ContainerWindow) {
        guard !applyingFrame else { return }
        let newFrame = Coords.toAX(window.frame)
        guard newFrame != frame else { return }
        frame = newFrame
        layout()
        delegate?.containerFrameChanged(self)
    }

    func containerWindowInteractionStarted(_ window: ContainerWindow) {
        // The click may have ordered the shell above the children; put them
        // back on top without touching the shell or keyboard focus.
        ignoreFocusUntil = Date().addingTimeInterval(0.2)
        raiseChildrenAboveShell(focus: activeChild)
    }

    func containerWindowInteractionEnded(_ window: ContainerWindow) {
        delegate?.containerInteractionEnded(self)
    }

    func containerWindowMoveEnded(_ window: ContainerWindow, at point: CGPoint) {
        delegate?.container(self, requestedGroupAt: point)
    }

    func containerWindowZoomRequested(_ window: ContainerWindow) {
        delegate?.containerZoomRequested(self)
    }

    func containerWindowCloseRequested(_ window: ContainerWindow) {
        delegate?.containerRequestedClose(self)
    }

    // MARK: Geometry

    var contentFrame: CGRect {
        CGRect(x: frame.minX + ContainerWindow.outerPadding,
               y: frame.minY + ContainerWindow.headerHeight,
               width: max(0, frame.width - ContainerWindow.outerPadding * 2),
               height: max(0, frame.height - ContainerWindow.headerHeight - ContainerWindow.outerPadding))
    }

    func frame(of child: CGWindowID) -> CGRect? {
        node?.frame(of: child, in: contentFrame, gutter: Self.gutter)
    }

    func setFrame(_ newFrame: CGRect) {
        frame = newFrame
        applyingFrame = true
        shell.setFrameWithoutNotifying(Coords.toAppKit(newFrame))
        applyingFrame = false
        layout()
        shell.contentView?.needsDisplay = true
        updateHeader()
    }

    /// After a move across displays the new screen may have a taller menu bar
    /// or a notch; keep the workspace header inside its visible area.
    func keepHeaderVisible() {
        let visible = Coords.visibleFrame(containing: frame)
        guard visible.width > 0, frame.minY < visible.minY else { return }
        var f = frame
        f.origin.y = visible.minY
        setFrame(f)
    }

    func layout() {
        guard let node, !children.isEmpty else {
            shell.paneRects = []
            hideChrome()
            return
        }
        let frames = node.frames(in: contentFrame, gutter: Self.gutter)
        let shellFrame = Coords.toAppKit(frame)
        shell.paneRects = frames.values.map {
            Coords.toAppKit($0).offsetBy(dx: -shellFrame.minX, dy: -shellFrame.minY)
        }
        for (id, rect) in frames {
            guard let w = children[id], let current = w.frame else { continue }
            if !current.equalTo(rect) { place(w, rect) }
        }
        syncSplitters()
        syncResizePanels()
        updateHeader()
    }

    private func place(_ w: Win, _ rect: CGRect) {
        w.setFrame(rect)
    }

    private func schedulePaneSettle(_ id: CGWindowID) {
        paneSettle[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.paneSettle[id] = nil
                guard let w = self.children[id], let target = self.frame(of: id),
                      let current = w.frame, !current.equalTo(target) else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.schedulePaneSettle(id)
                    return
                }
                guard target.width >= w.minSize.width, target.height >= w.minSize.height else { return }
                self.place(w, target)
            }
        }
        paneSettle[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private var minSizes: [CGWindowID: CGSize] {
        Dictionary(uniqueKeysWithValues: children.map { ($0.key, $0.value.minSize) })
    }

    // MARK: Children

    @discardableResult
    func insert(_ w: Win, targetChild: CGWindowID?, at point: CGPoint?, preferFirst: Bool? = nil,
                axisOverride: SplitAxis? = nil) -> Bool {
        guard children[w.id] == nil, children.count < Self.maxChildren else { return false }
        if let f = w.frame { preFrames[w.id] = f }
        children[w.id] = w
        order.append(w.id)

        guard let existing = node else {
            node = .leaf(w.id)
            activeChild = w.id
            layout()
            delegate?.containerNeedsTabRefresh(self)
            return true
        }

        let target = targetChild.flatMap { existing.leafIDs.contains($0) ? $0 : nil }
            ?? existing.largestLeaf(in: contentFrame, gutter: Self.gutter)?.0
            ?? existing.leafIDs.first
        guard let target else { return false }
        let targetFrame = existing.frame(of: target, in: contentFrame, gutter: Self.gutter) ?? contentFrame
        let axis: SplitAxis
        if let axisOverride {
            axis = axisOverride
        } else if targetChild == nil {
            // Dropped on the container background: split the leaf along its
            // longer side; the new pane goes right/bottom by default.
            axis = targetFrame.width >= targetFrame.height ? .vertical : .horizontal
        } else {
            axis = splitAxis(for: targetFrame, at: point)
        }
        let newFirst = preferFirst ?? defaultNewFirst(in: targetFrame, axis: axis, at: point)
        node = existing.inserting(w.id, at: target, axis: axis, newFirst: newFirst)
        activeChild = w.id
        layout()
        delegate?.containerNeedsTabRefresh(self)
        return true
    }

    func removeChild(_ id: CGWindowID, restoreFrame: Bool) {
        guard let w = children[id] else { return }
        if restoreFrame, let f = preFrames[id] {
            w.setFrame(f)
        }
        children[id] = nil
        preFrames[id] = nil
        paneSettle[id]?.cancel()
        paneSettle[id] = nil
        paneCommit[id] = nil
        order.removeAll { $0 == id }
        if let n = node?.removing(id) {
            node = n.leafIDs.isEmpty ? nil : n
        } else {
            node = nil
        }
        if activeChild == id { activeChild = order.first }
        if order.isEmpty { order = Array(children.keys) }
        if isActive, let next = activeChild, let w = children[next] { w.raise() }
        if children.isEmpty {
            hideChrome()
            delegate?.containerDidBecomeEmpty(self)
            return
        }
        layout()
        delegate?.containerNeedsTabRefresh(self)
    }

    func setActiveChild(_ id: CGWindowID) {
        guard children[id] != nil, activeChild != id else { return }
        activeChild = id
        updateHeader()
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = (trimmed?.isEmpty == false) ? trimmed : nil
        updateHeader()
        delegate?.containerNeedsTabRefresh(self)
    }

    /// 从别的容器搬过来时保留它最初离开普通窗口时的 frame。
    func setPreFrame(_ id: CGWindowID, _ frame: CGRect) {
        guard children[id] != nil else { return }
        preFrames[id] = frame
    }

    // MARK: Activation

    func activate() {
        guard !children.isEmpty else { return }
        isActive = true
        let focusID = activeChild ?? order.first ?? children.keys.first!
        activeChild = focusID
        // Bring the container tab in front once, then its children above the
        // shell. Do not repeat this on focus events: re-ordering the shell
        // there makes the dark background flash over the panes.
        ignoreFocusUntil = Date().addingTimeInterval(0.3)
        shell.orderFrontRegardless()
        raiseChildrenAboveShell(focus: focusID)
        children[focusID]?.raise()
        updateHeader()
    }

    /// Bring the whole workspace forward when one of its children is
    /// activated from outside (for example from the Dock), without taking
    /// keyboard focus away from that child.
    private func bringForward(focus: CGWindowID?) {
        guard !bringingForward else { return }
        bringingForward = true
        ignoreFocusUntil = Date().addingTimeInterval(0.3)
        shell.orderFrontRegardless()
        raiseChildrenAboveShell(focus: focus ?? activeChild)
        updateHeader()
        bringingForward = false
    }

    /// Raise children above the shell without changing keyboard focus.
    private func raiseChildrenAboveShell(focus: CGWindowID?) {
        let f = focus ?? activeChild
        let raised = order.filter { $0 != f }
        for id in raised { children[id]?.orderFront() }
        if let f { children[f]?.orderFront() }
        orderShellBelowChildren()
        scheduleShellBelowChildren()
        orderChromeAboveChildren()
    }

    /// The children are raised asynchronously by their apps; re-assert the
    /// shell's position below the actual lowest visible pane. Do not raise the
    /// children again here: repeated AX raises make their title bars/content
    /// flicker for a moment when a workspace is reactivated.
    private func orderShellBelowChildren() {
        guard shell.isVisible, !children.isEmpty else { return }
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return }
        var lowest: CGWindowID?
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            let id = CGWindowID(number)
            if children[id] != nil { lowest = id }
        }
        if let lowest { shell.order(.below, relativeTo: Int(lowest)) }
    }

    private func scheduleShellBelowChildren() {
        for delay in [0.08, 0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.reassertChildrenAboveShell() }
            }
        }
    }

    /// Apps raise their windows asynchronously, and the window being dragged
    /// can still be settling. Only re-assert the shell below the panes here;
    /// raising every child again makes their windows visibly flicker.
    private func reassertChildrenAboveShell() {
        guard shell.isVisible, isActive, !children.isEmpty else { return }
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              children.values.contains(where: { $0.pid == front }) else { return }
        ignoreFocusUntil = Date().addingTimeInterval(0.3)
        orderShellBelowChildren()
        orderChromeAboveChildren()
    }

    /// Whether no other app's window is above this container's shell, and
    /// every child is above the shell.
    private func isFrontmostEnough() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        let ownPID = getpid()
        let childIDs = Set(children.keys)
        var sawShell = false
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            let id = CGWindowID(number)
            if id == anchorID {
                sawShell = true
                continue
            }
            if childIDs.contains(id) {
                if sawShell { return false }   // a pane is below the shell
                continue
            }
            if !sawShell {
                if (info[kCGWindowOwnerPID as String] as? Int32) == ownPID,
                   let window = NSApp.window(withWindowNumber: Int(id)),
                   window is TabStripPanel || window is SplitterPanel
                    || window is ContainerResizePanel || window.ignoresMouseEvents {
                    continue
                }
                // Another app or an unrelated own window above the shell.
                return false
            }
            // Below the shell: irrelevant.
        }
        return sawShell
    }

    func deactivate() {
        isActive = false
        hideChrome()
    }

    /// 只更新激活态和分割线层级，不抢焦点；用于 TabGroups 在焦点变化后
    /// 同步“哪一个是当前 tab”，而不是用户主动点击切换 tab。
    func markActive() {
        isActive = true
        orderChromeAboveChildren()
        updateHeader()
    }

    // MARK: Splitter

    private func syncSplitters() {
        guard let node else { hideChrome(); return }
        let infos = node.splitters(in: contentFrame, gutter: Self.gutter, minSizes: minSizes)
        let live = Set(infos.map(\.id))
        for (id, panel) in Array(splitterPanels) where !live.contains(id) {
            panel.orderOut(nil)
            splitterPanels[id] = nil
        }
        for info in infos {
            let panel = splitterPanels[info.id] ?? makeSplitter(info.id, axis: info.axis)
            splitterPanels[info.id] = panel
            let hit: CGRect
            if info.axis == .vertical {
                hit = CGRect(x: info.band.midX - 5, y: info.band.minY, width: 10, height: info.band.height)
            } else {
                hit = CGRect(x: info.band.minX, y: info.band.midY - 5, width: info.band.width, height: 10)
            }
            panel.setFrame(Coords.toAppKit(hit), display: true)
            if !isActive { panel.orderOut(nil) }
        }
        if isActive { orderChromeAboveChildren() }
    }

    private func makeSplitter(_ id: UUID, axis: SplitAxis) -> SplitterPanel {
        let panel = SplitterPanel(
            axis: axis,
            onDrag: { [weak self] point in self?.dragSplitter(id, to: point) },
            onReset: { [weak self] in self?.resetSplitter(id) }
        )
        return panel
    }

    private func dragSplitter(_ id: UUID, to point: CGPoint) {
        guard let node,
              let info = node.splitters(in: contentFrame, gutter: Self.gutter, minSizes: minSizes)
                .first(where: { $0.id == id }) else { return }
        let available = info.axis == .vertical
            ? info.parent.width - Self.gutter
            : info.parent.height - Self.gutter
        guard available > 1 else { return }
        let raw = info.axis == .vertical
            ? (point.x - info.parent.minX) / available
            : (point.y - info.parent.minY) / available
        let lower = max(0.15, info.firstMin / available)
        let upper = min(0.85, 1 - info.secondMin / available)
        guard lower <= upper else { return }
        let ratio = min(max(raw, lower), upper)
        self.node = node.updatingRatio(of: id, to: ratio)
        layout()
    }

    private func resetSplitter(_ id: UUID) {
        guard let node else { return }
        self.node = node.updatingRatio(of: id, to: 0.5)
        layout()
    }

    private func orderChromeAboveChildren() {
        guard let top = activeChild ?? order.last else { return }
        for panel in splitterPanels.values {
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.order(.above, relativeTo: Int(top))
        }
        for panel in resizePanels.values {
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.order(.above, relativeTo: Int(top))
        }
    }

    private func hideChrome() {
        for panel in splitterPanels.values { panel.orderOut(nil) }
        for panel in resizePanels.values { panel.orderOut(nil) }
    }

    private func syncResizePanels() {
        let s = Coords.toAppKit(frame)
        let thickness: CGFloat = 8
        let bodyHeight = max(0, s.height - ContainerWindow.headerHeight)
        resizePanels[.left]?.setFrame(NSRect(x: s.minX, y: s.minY, width: thickness, height: bodyHeight),
                                      display: false)
        resizePanels[.right]?.setFrame(NSRect(x: s.maxX - thickness, y: s.minY, width: thickness, height: bodyHeight),
                                       display: false)
        resizePanels[.bottom]?.setFrame(NSRect(x: s.minX + thickness, y: s.minY,
                                               width: max(0, s.width - thickness * 2), height: thickness),
                                        display: false)
        if isActive {
            orderChromeAboveChildren()
        } else {
            for panel in resizePanels.values { panel.orderOut(nil) }
        }
    }

    private func updateHeader() {
        shell.titleText = title
        shell.countText = "\(count)"
    }

    // MARK: Events from child windows

    func handleChildEvent(_ w: Win, _ kind: ChildEvent) -> Bool {
        guard children[w.id] != nil else { return false }
        switch kind {
        case .moved, .resized:
            // A pane must stay in its slot. Re-apply the pane frame whenever the
            // child actually moved/resized (including its own edge drag); skip
            // it when the frame already equals the target (our own AX write).
            if let rect = frame(of: w.id), let current = w.frame, !current.equalTo(rect) {
                schedulePaneSettle(w.id, commit: paneCommitKind(for: w.id))
            }
        case .focused:
            if let until = ignoreFocusUntil, until > Date() { return true }
            setActiveChild(w.id)
            guard isActive else { return true }
            if isFrontmostEnough() {
                orderChromeAboveChildren()
            } else {
                bringForward(focus: w.id)
            }
        case .titleChanged:
            updateHeader()
            if w.id == activeChild { delegate?.containerNeedsTabRefresh(self) }
        case .destroyed, .minimized:
            removeChild(w.id, restoreFrame: false)
        }
        return true
    }

    // MARK: Teardown

    /// 把子窗口放回容器前的位置，然后关掉壳。
    func releaseChildren() {
        for work in paneSettle.values { work.cancel() }
        paneSettle.removeAll()
        paneCommit.removeAll()
        for (id, w) in children {
            if let f = preFrames[id] {
                w.setFrame(f)
            }
        }
        children.removeAll()
        preFrames.removeAll()
        order.removeAll()
        node = nil
        activeChild = nil
        hideChrome()
        shell.orderOut(nil)
    }

    // MARK: Layout helpers

    private func splitAxis(for rect: CGRect, at point: CGPoint?) -> SplitAxis {
        guard let point else { return rect.width >= rect.height ? .vertical : .horizontal }
        let nx = (point.x - rect.midX) / max(1, rect.width)
        let ny = (point.y - rect.midY) / max(1, rect.height)
        if abs(nx) > abs(ny) * 1.2 { return .vertical }
        if abs(ny) > abs(nx) * 1.2 { return .horizontal }
        return rect.width >= rect.height ? .vertical : .horizontal
    }

    private func defaultNewFirst(in rect: CGRect, axis: SplitAxis, at point: CGPoint?) -> Bool {
        guard let point else { return false }
        return axis == .vertical ? point.x < rect.midX : point.y < rect.midY
    }

    // MARK: Icon

    static let gridIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.9).setFill()
            let s: CGFloat = 6
            for row in 0..<2 {
                for col in 0..<2 {
                    let r = NSRect(x: 1 + CGFloat(col) * 8, y: 1 + CGFloat(row) * 8, width: s, height: s)
                    NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }()
}

enum ChildEvent {
    case moved, resized, focused, titleChanged, destroyed, minimized
}
