import AppKit

@MainActor
protocol ContainerWindowEvents: AnyObject {
    func containerWindowFrameChanged(_ window: ContainerWindow)
    func containerWindowInteractionStarted(_ window: ContainerWindow)
    func containerWindowInteractionEnded(_ window: ContainerWindow)
    func containerWindowMoveEnded(_ window: ContainerWindow, at point: CGPoint)
    func containerWindowZoomRequested(_ window: ContainerWindow)
    func containerWindowCloseRequested(_ window: ContainerWindow)
}

/// 容器壳：只负责背景、顶部细标题栏、外边框和缩放；真正的子窗口是别的 App 的窗口。
@MainActor
final class ContainerWindow: NSPanel, NSWindowDelegate {
    static let headerHeight: CGFloat = 28
    static let outerPadding: CGFloat = 6

    weak var events: ContainerWindowEvents?
    private let shellView = ContainerShellView()
    private var suppressingFrameEvents = false

    var titleText: String = "Workspace" {
        didSet { shellView.titleText = titleText }
    }
    var countText: String = "" {
        didSet { shellView.countText = countText }
    }
    /// Pane frames in the shell's local coordinates; the shell fill leaves
    /// these holes transparent, so a momentary shell-above flash cannot dim
    /// the child windows.
    var paneRects: [CGRect] = [] {
        didSet { shellView.paneRects = paneRects }
    }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none

        shellView.events = self
        shellView.titleText = titleText
        shellView.autoresizingMask = [.width, .height]
        shellView.wantsLayer = true
        shellView.layer?.cornerRadius = Style.containerCorner
        shellView.layer?.masksToBounds = true
        contentView = shellView
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 由容器设置 frame 时不要反过来通知它自己。
    func setFrameWithoutNotifying(_ frame: NSRect) {
        suppressingFrameEvents = true
        setFrame(frame, display: true)
        suppressingFrameEvents = false
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
    }

    func windowDidMove(_ notification: Notification) {
        guard !suppressingFrameEvents else { return }
        events?.containerWindowFrameChanged(self)
    }

    func windowDidResize(_ notification: Notification) {
        guard !suppressingFrameEvents else { return }
        events?.containerWindowFrameChanged(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        events?.containerWindowCloseRequested(self)
        return false
    }
}

/// 壳体内容：标题栏、边框、右下角缩放提示，以及壳自己的拖动/缩放手势。
@MainActor
final class ContainerShellView: NSView {
    weak var events: ContainerWindowEvents?
    var titleText = "Workspace" {
        didSet { needsDisplay = true }
    }
    var countText = "" {
        didSet { needsDisplay = true }
    }
    var paneRects: [CGRect] = [] {
        didSet { needsDisplay = true }
    }

    private enum DragMode: Equatable {
        case none
        case move
        case resize(ResizeEdges)
    }

    private struct ResizeEdges: OptionSet, Equatable {
        let rawValue: Int
        static let left = ResizeEdges(rawValue: 1)
        static let right = ResizeEdges(rawValue: 2)
        static let bottom = ResizeEdges(rawValue: 4)
        static let top = ResizeEdges(rawValue: 8)
    }

    private var mode: DragMode = .none
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Moving between displays with different backing scales can leave the
    /// layer-backed header stale until something else forces a redraw.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func resetCursorRects() {
        let edge: CGFloat = 7
        let bodyTop = bounds.height - ContainerWindow.headerHeight
        addCursorRect(NSRect(x: 0, y: edge, width: edge, height: max(0, bodyTop - edge)),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edge, y: edge, width: edge, height: max(0, bodyTop - edge)),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: edge, y: 0, width: bounds.width - edge * 2, height: edge),
                      cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = Style.containerCorner
        let outline = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        // Light tint only: if the shell ever ends up above a pane, it must
        // dim it rather than black it out. Pane holes stay transparent so a
        // brief z-order flash does not visibly dim the child windows.
        let fill = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        if !paneRects.isEmpty {
            for rect in paneRects {
                fill.append(NSBezierPath(rect: rect))
            }
            fill.windingRule = .evenOdd
        }
        NSColor(srgbRed: 26 / 255, green: 28 / 255, blue: 31 / 255, alpha: 0.28).setFill()
        fill.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        outline.stroke()

        let header = NSRect(x: 0, y: bounds.height - ContainerWindow.headerHeight,
                            width: bounds.width, height: ContainerWindow.headerHeight)
        // The header never overlaps a pane, so it can stay nearly opaque.
        NSColor(srgbRed: 26 / 255, green: 28 / 255, blue: 31 / 255, alpha: 0.94).setFill()
        header.fill()
        NSColor.white.withAlphaComponent(0.04).setFill()
        header.fill()
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: header.minY, width: bounds.width, height: 1).fill()

        drawGridIcon(at: NSPoint(x: 10, y: header.midY - 7))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.86),
        ]
        (titleText as NSString).draw(at: NSPoint(x: 34, y: header.midY - 8), withAttributes: attrs)
        if !countText.isEmpty {
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.42),
            ]
            let w = (countText as NSString).size(withAttributes: countAttrs).width
            (countText as NSString).draw(at: NSPoint(x: bounds.width - w - 10, y: header.midY - 8),
                                        withAttributes: countAttrs)
        }

        // 右下角缩放提示，三条短线。
        NSColor.white.withAlphaComponent(0.18).setStroke()
        for i in 0..<3 {
            let x = bounds.width - 10 - CGFloat(i) * 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 4))
            path.line(to: NSPoint(x: bounds.width - 4, y: 4 + CGFloat(i) * 4))
            path.stroke()
        }
    }

    private func drawGridIcon(at origin: NSPoint) {
        NSColor.white.withAlphaComponent(0.55).setFill()
        let s: CGFloat = 6
        for row in 0..<2 {
            for col in 0..<2 {
                let rect = NSRect(x: origin.x + CGFloat(col) * (s + 2), y: origin.y + CGFloat(row) * (s + 2),
                                  width: s, height: s)
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    private func edges(at p: NSPoint) -> ResizeEdges {
        let edge: CGFloat = 7
        var out: ResizeEdges = []
        if p.x <= edge { out.insert(.left) }
        if p.x >= bounds.width - edge { out.insert(.right) }
        if p.y <= edge { out.insert(.bottom) }
        if p.y >= bounds.height - edge { out.insert(.top) }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        if let window = window as? ContainerWindow {
            events?.containerWindowInteractionStarted(window)
        }
        let p = convert(event.locationInWindow, from: nil)
        if p.y >= bounds.height - ContainerWindow.headerHeight {
            if event.clickCount == 2 {
                mode = .none
                if let window = window as? ContainerWindow {
                    events?.containerWindowZoomRequested(window)
                }
                return
            }
            mode = .move
        } else {
            let e = edges(at: p)
            mode = e.isEmpty ? .none : .resize(e)
        }
        guard mode != .none else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, mode != .none else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x
        let dy = p.y - startMouse.y

        switch mode {
        case .none:
            return
        case .move:
            window.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
        case let .resize(e):
            var f = startFrame
            let minW: CGFloat = 320
            let minH: CGFloat = 220
            if e.contains(.left) {
                f.origin.x = startFrame.minX + dx
                f.size.width = startFrame.width - dx
            }
            if e.contains(.right) { f.size.width = startFrame.width + dx }
            if e.contains(.bottom) {
                f.origin.y = startFrame.minY + dy
                f.size.height = startFrame.height - dy
            }
            if e.contains(.top) { f.size.height = startFrame.height + dy }
            if f.width < minW {
                if e.contains(.left) { f.origin.x = startFrame.maxX - minW }
                f.size.width = minW
            }
            if f.height < minH {
                if e.contains(.bottom) { f.origin.y = startFrame.maxY - minH }
                f.size.height = minH
            }
            window.setFrame(f, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode != .none else { return }
        let wasMove: Bool
        if case .move = mode { wasMove = true } else { wasMove = false }
        mode = .none
        if let window = window as? ContainerWindow {
            events?.containerWindowInteractionEnded(window)
            if wasMove {
                events?.containerWindowMoveEnded(window, at: Coords.cursor())
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let window = window as? ContainerWindow {
            events?.containerWindowInteractionStarted(window)
        }
        let menu = NSMenu()
        let close = menu.addItem(withTitle: "Close Container", action: #selector(closeContainer), keyEquivalent: "")
        close.target = self
        return menu
    }

    @objc private func closeContainer() {
        guard let window = window as? ContainerWindow else { return }
        events?.containerWindowCloseRequested(window)
    }
}

/// 内部分割线的拖动手柄。每个分割线一个透明小 panel，位于子窗口之上。
@MainActor
final class SplitterPanel: NSPanel {
    private let splitView: SplitterView
    let axis: SplitAxis

    init(axis: SplitAxis, onDrag: @escaping (CGPoint) -> Void, onReset: @escaping () -> Void) {
        self.axis = axis
        self.splitView = SplitterView(axis: axis)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle, .transient]
        animationBehavior = .none
        splitView.onDrag = onDrag
        splitView.onReset = onReset
        contentView = splitView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension ContainerWindow: ContainerWindowEvents {
    func containerWindowFrameChanged(_ window: ContainerWindow) {
        events?.containerWindowFrameChanged(window)
    }

    func containerWindowInteractionStarted(_ window: ContainerWindow) {
        events?.containerWindowInteractionStarted(window)
    }

    func containerWindowInteractionEnded(_ window: ContainerWindow) {
        events?.containerWindowInteractionEnded(window)
    }

    func containerWindowMoveEnded(_ window: ContainerWindow, at point: CGPoint) {
        events?.containerWindowMoveEnded(window, at: point)
    }

    func containerWindowZoomRequested(_ window: ContainerWindow) {
        events?.containerWindowZoomRequested(window)
    }

    func containerWindowCloseRequested(_ window: ContainerWindow) {
        events?.containerWindowCloseRequested(window)
    }
}

@MainActor
private final class SplitterView: NSView {
    var onDrag: ((CGPoint) -> Void)?
    var onReset: (() -> Void)?
    private let axis: SplitAxis
    private var hovered = false

    init(axis: SplitAxis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.white.withAlphaComponent(hovered ? 0.55 : 0.26)
        color.setFill()
        let thickness: CGFloat = 3
        if axis == .vertical {
            let rect = NSRect(x: bounds.midX - thickness / 2, y: 6, width: thickness, height: bounds.height - 12)
            NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        } else {
            let rect = NSRect(x: 6, y: bounds.midY - thickness / 2, width: bounds.width - 12, height: thickness)
            NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        (axis == .vertical ? NSCursor.resizeLeftRight : .resizeUpDown).set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?() }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(Coords.toAX(NSEvent.mouseLocation))
    }
}

enum ContainerResizeEdge: Hashable {
    case left, right, bottom
}

/// Outer-edge resize handle: a thin transparent panel above the children, so
/// grabbing near the container border resizes the shell, not a child window.
@MainActor
final class ContainerResizePanel: NSPanel {
    weak var shellWindow: ContainerWindow?
    private let handleView: ContainerResizeView

    init(edge: ContainerResizeEdge, onFrame: @escaping (NSRect) -> Void, onEnd: @escaping () -> Void) {
        self.handleView = ContainerResizeView(edge: edge)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = [.ignoresCycle, .transient]
        animationBehavior = .none
        handleView.onFrame = onFrame
        handleView.onEnd = onEnd
        contentView = handleView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ContainerResizeView: NSView {
    private let edge: ContainerResizeEdge
    var onFrame: ((NSRect) -> Void)?
    var onEnd: (() -> Void)?
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(edge: ContainerResizeEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        switch edge {
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .bottom: NSCursor.resizeUpDown.set()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch edge {
        case .left, .right: cursor = .resizeLeftRight
        case .bottom: cursor = .resizeUpDown
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? ContainerResizePanel,
              let shell = panel.shellWindow else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = shell.frame
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x
        let dy = p.y - startMouse.y
        var f = startFrame
        let minW: CGFloat = 320
        let minH: CGFloat = 220

        switch edge {
        case .left:
            f.origin.x = startFrame.minX + dx
            f.size.width = startFrame.width - dx
            if f.width < minW {
                f.origin.x = startFrame.maxX - minW
                f.size.width = minW
            }
        case .right:
            f.size.width = startFrame.width + dx
            if f.size.width < minW { f.size.width = minW }
        case .bottom:
            f.origin.y = startFrame.minY + dy
            f.size.height = startFrame.height - dy
            if f.height < minH {
                f.origin.y = startFrame.maxY - minH
                f.size.height = minH
            }
        }
        onFrame?(f)
    }

    override func mouseUp(with event: NSEvent) {
        onEnd?()
    }
}
