import AppKit

/// Held down, it turns a press anywhere in a window into a window drag, and
/// only while it's held does a drag make a group.
enum DragKey: String, CaseIterable {
    case command, option, control, fn

    static var current: DragKey {
        get { UserDefaults.standard.string(forKey: "dragKey").flatMap(DragKey.init) ?? .command }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dragKey") }
    }

    var flag: CGEventFlags {
        switch self {
        case .command: .maskCommand
        case .option: .maskAlternate
        case .control: .maskControl
        case .fn: .maskSecondaryFn
        }
    }

    var title: String {
        switch self {
        case .command: "⌘ Command"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .fn: "fn"
        }
    }

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .fn: .function
        }
    }
}

/// Held with 1…9, it switches tabs in the focused window's group. ⌥ by
/// default: apps' own ⌘1…⌘9 (Electron apps, browsers, Ghostty) mostly live
/// outside their menus, so there's no telling which apps use them.
enum SwitchKey: String, CaseIterable {
    case option, control, command, controlOption

    static var current: SwitchKey {
        get { UserDefaults.standard.string(forKey: "switchKey").flatMap(SwitchKey.init) ?? .option }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "switchKey") }
    }

    var flags: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .control: .maskControl
        case .command: .maskCommand
        case .controlOption: [.maskControl, .maskAlternate]
        }
    }

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        case .controlOption: "⌃⌥"
        }
    }

    var title: String {
        switch self {
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        case .controlOption: "⌃⌥ Control-Option"
        }
    }

    /// With ⌘, a window's own tab bar keeps ⌘1…⌘9 for its own tabs.
    @MainActor func yields(to window: Win) -> Bool {
        self == .command && AX.hasOwnTabs(window.element)
    }
}

/// Watches the user dragging other apps' windows by their title bars.
/// Drop one on the *middle* of another and hold still for a moment → they
/// become tabs of one group. (TrellisWM: "Drag a window onto the middle of
/// another and pause a moment.")
@MainActor
final class DragController {
    var holdDuration: TimeInterval = 0.35
    var holdSlop: CGFloat = 4               // "still" = the pointer stays this close the whole time
    var middleInset: CGFloat = 0.25         // outer 25% of each side is "edge", not "middle"

    private let tracker: WindowTracker
    private let groups: GroupManager
    private let highlight = DropHighlight()

    private var monitors: [Any] = []
    private var source: Win?
    private var sourceStart: CGRect?
    private var moving = false
    private var ticker: Timer?

    @MainActor
    private enum DropTarget {
        case window(Win, CGRect)
        /// ⌘ 拖到容器上：把窗口加成容器所在分组的一个 tab。
        case containerTab(Container, CGRect)
        /// ⇧ 拖到容器里：把窗口加成容器子窗口。
        case containerInsert(Container, CGWindowID?, CGRect)
        /// ⇧ 把窗口拖到另一个普通窗口上：新建容器。
        case newContainer(Win, CGRect)

        var area: CGRect {
            switch self {
            case let .window(_, rect): rect
            case let .containerTab(_, rect): rect
            case let .containerInsert(_, _, rect): rect
            case let .newContainer(_, rect): rect
            }
        }

        var key: String {
            switch self {
            case let .window(w, _): "w-\(w.id)"
            case let .containerTab(c, _): "ct-\(c.anchorID)"
            case let .containerInsert(c, child, _): "ci-\(c.anchorID)-\(child ?? 0)"
            case let .newContainer(w, _): "nc-\(w.id)"
            }
        }

        var usesStrip: Bool {
            if case .window = self { return true }
            return false
        }
    }

    private var dropTarget: DropTarget?
    private var anchor: CGPoint = .zero
    private var since = Date.distantFuture
    private var armed = false

    private var tap: CFMachPort?
    /// Taken from the event stream: the polled modifier state
    /// (`CGEventSource.flagsState`) drops it for a moment when a dragged
    /// window crosses to another display.
    private var keyHeld = false
    private var shiftHeld = false
    /// Also from the event stream: while the tap swallows a drag,
    /// `NSEvent.mouseLocation` stays where the button went down.
    private var pointer: CGPoint = .zero
    /// Pointer offset into the window being moved with the drag key.
    private var grab: CGPoint?
    private var pressPoint: CGPoint = .zero
    /// The swallowed press, replayed if it turns out to be a plain click.
    private var pressed: CGEvent?
    fileprivate static let replayTag: Int64 = 0x7461_6267   // "tabg"

    init(tracker: WindowTracker, groups: GroupManager) {
        self.tracker = tracker
        self.groups = groups
    }

    func start() {
        // Global monitors see events going to other apps (not our own panels).
        // Rectangle uses the same approach for its snap areas; a CGEventTap
        // would also work.
        let watch: [(NSEvent.EventTypeMask, @MainActor (DragController) -> Void)] = [
            (.leftMouseDown, { $0.mouseDown() }),
            (.leftMouseDragged, { $0.mouseDragged() }),
            (.leftMouseUp, { $0.mouseUp() }),
        ]
        for (mask, action) in watch {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { if let self { action(self) } }
            }) {
                monitors.append(m)
            }
        }

        // Presses with the drag key go through an active tap instead: the
        // app under the pointer must not see them. (Swallowed events never
        // reach the monitors above.)
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
            .reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: tapCallback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { NSLog("TabGroups: couldn't create the event tap"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    /// Returns false to swallow the event.
    fileprivate func handleTap(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag { return true }
        if type == .keyDown { return !switchTab(event) }
        if type != .tapDisabledByTimeout && type != .tapDisabledByUserInput {
            keyHeld = event.flags.contains(DragKey.current.flag)
            shiftHeld = event.flags.contains(.maskShift)
            pointer = event.location
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .leftMouseDown:
            return !keyDown(event)
        case .leftMouseDragged:
            guard grab != nil else { return true }
            keyDragged(event.location)
            return false
        case .leftMouseUp:
            guard grab != nil else { return true }
            let window = source
            let doubleClick = pressed?.getIntegerValueField(.mouseEventClickState) == 2
            let click = pressed.flatMap { down in event.copy().map { [down, $0] } }
            mouseUp()
            if doubleClick, let window { titleBarDoubleClick(window); return false }
            for e in click ?? [] {
                e.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
                e.post(tap: .cgSessionEventTap)
            }
            return false
        default:
            return true
        }
    }

    /// ANSI key codes of 1…9 (physical keys, so it works on any layout).
    private static let digitKeys: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// Switch key + 1…8 shows that tab of the focused window's group, + 9
    /// the last one (as in Ghostty and browsers). Returns true when it was ours.
    private func switchTab(_ event: CGEvent) -> Bool {
        let key = SwitchKey.current
        let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard mods == key.flags,
              let n = Self.digitKeys.firstIndex(of: event.getIntegerValueField(.keyboardEventKeycode)),
              let id = groups.focused, let g = groups.group(of: id) else { return false }
        if let w = tracker.windows[id], key.yields(to: w) { return false }
        if let c = groups.containers[id], let child = c.activeChild,
           let w = tracker.windows[child], key.yields(to: w) { return false }
        let i = n == 8 ? g.tabs.count - 1 : n
        // Out of range or held down: still ours, the app's own use would confuse.
        if i < g.tabs.count, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, g.tabs[i] != g.active {
            groups.select(g.tabs[i], in: g)
        }
        return true
    }

    /// A press with the drag key on a tracked window: we'll move it ourselves.
    private func keyDown(_ event: CGEvent) -> Bool {
        guard event.flags.contains(DragKey.current.flag) else { return false }
        let p = event.location
        // Our own strips and windows handle their own clicks. (Click-through
        // ones, like the strip's shadow, don't count: this hit test doesn't
        // skip them.)
        let n = NSWindow.windowNumber(at: NSPoint(x: p.x, y: Coords.primaryHeight - p.y),
                                      belowWindowWithWindowNumber: 0)
        guard NSApp.window(withWindowNumber: n).map({ $0.ignoresMouseEvents }) ?? true,
              let w = tracker.topWindow(at: p), let f = w.frame,
              !groups.containers.isChild(w.id) else { return false }
        reset()
        source = w
        sourceStart = f
        grab = CGPoint(x: p.x - f.minX, y: p.y - f.minY)
        pressPoint = p
        pressed = event.copy()
        return true
    }

    private func keyDragged(_ p: CGPoint) {
        guard let w = source, let start = sourceStart, let grab else { return }
        if !moving {
            guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 3 else { return }   // still a click
            pressed = nil
            w.raise()
            startMoving()
        }
        let origin = CGPoint(x: p.x - grab.x, y: p.y - grab.y)
        AX.withoutEnhancedUI(w.appElement) { AX.setPosition(w.element, origin) }
        groups.dragMoved(w.id, frame: CGRect(origin: origin, size: start.size))
        evaluate()
    }

    /// Whatever double-clicking the title bar does
    /// (System Settings ▸ Desktop & Dock).
    private func titleBarDoubleClick(_ w: Win) {
        let d = UserDefaults.standard
        let action = d.string(forKey: "AppleActionOnDoubleClick")
            ?? (d.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize": AX.set(w.element, kAXMinimizedAttribute, kCFBooleanTrue)
        case "None": break
        // ponytail: "Fill" zooms too (most apps zoom to the whole screen anyway);
        // set the frame to the visible frame if that falls short.
        default:
            // Option-click on the green button. Reports an error but zooms.
            if let b = AX.element(w.element, kAXZoomButtonAttribute) { AX.perform(b, "AXZoomWindow") }
        }
    }

    private func startMoving() {
        moving = true
        // Keep evaluating while the pointer rests: no drag events arrive then.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    private func mouseDown() {
        reset()
        guard let w = tracker.topWindow(at: Coords.cursor()) else { return }
        source = w
        sourceStart = w.serverFrame
    }

    private func mouseDragged() {
        guard let w = source, let start = sourceStart else { return }
        if !moving {
            // Is the window itself moving (a title-bar drag), not a text selection?
            guard let f = w.serverFrame, f.size == start.size, f.origin != start.origin else { return }
            startMoving()
        }
        if let f = w.serverFrame { groups.dragMoved(w.id, frame: f) }
        evaluate()
    }

    private func mouseUp() {
        let target = armed ? dropTarget : nil
        let containerKey = shiftHeld
        let dragKey = keyHeld
        let src = source
        let startFrame = sourceStart
        reset()
        guard let target, let src else { return }
        // Let the WindowServer finish its own drag first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch target {
                case let .containerInsert(container, child, _):
                    if containerKey {
                        _ = self.groups.containers.insert(src, into: container,
                                                          targetChild: child, at: self.pointer,
                                                          sourceFrame: startFrame)
                    }
                case let .newContainer(window, _):
                    if containerKey {
                        _ = self.groups.containers.create(from: src, and: window, at: self.pointer,
                                                          sourceFrame: startFrame)
                    }
                case let .containerTab(container, _):
                    if dragKey { self.groups.join(src, ontoContainer: container) }
                case let .window(window, _):
                    if dragKey { self.groups.join(src, onto: window) }
                }
            }
        }
    }

    private func evaluate() {
        guard moving, let src = source else { return }
        let p = pointer
        var excluded = Set(groups.group(of: src.id)?.tabs ?? [src.id])
        if let c = groups.containers.container(forChild: src.id) {
            excluded.formUnion(c.children.keys)
        }

        if shiftHeld {
            if let target = containerTarget(at: p, excluding: excluded, source: src) {
                setDropTarget(target, at: p, immediate: true)
            } else {
                disarm()
            }
            return
        }

        guard keyHeld else { disarm(); return }
        if let target = groupTarget(at: p, excluding: excluded, source: src) {
            setDropTarget(target, at: p, immediate: false)
        } else {
            disarm()
        }
    }

    private func isMiddle(_ rect: CGRect, _ p: CGPoint) -> Bool {
        rect.insetBy(dx: rect.width * middleInset, dy: rect.height * middleInset).contains(p)
    }

    private func containerTarget(at p: CGPoint, excluding: Set<CGWindowID>, source: Win) -> DropTarget? {
        if let (container, child) = groups.containers.target(at: p, excluding: excluding) {
            guard container.isActive, !container.children.keys.contains(source.id),
                  container.count < Container.maxChildren else { return nil }
            let content = container.contentFrame
            // “拖到容器中间”优先当成整容器插入：选面积最大的 pane 再二分。
            if content.insetBy(dx: content.width * 0.3, dy: content.height * 0.3).contains(p) {
                return .containerInsert(container, nil, content)
            }
            if let child, let zone = container.frame(of: child) {
                guard isMiddle(zone, p) else { return nil }
                return .containerInsert(container, child, zone)
            }
            return .containerInsert(container, nil, content)
        }
        if let w = tracker.topWindow(at: p, excluding: excluding), w.id != source.id,
           !groups.containers.isChild(w.id), let f = w.frame, isMiddle(f, p) {
            return .newContainer(w, f)
        }
        return nil
    }

    private func groupTarget(at p: CGPoint, excluding: Set<CGWindowID>, source: Win) -> DropTarget? {
        if let g = groups.group(atStrip: p), !g.tabs.contains(source.id) {
            if let c = groups.containers[g.active] {
                return .containerTab(c, g.frame)
            }
            if let w = tracker.windows[g.active] {
                return .window(w, g.frame)
            }
        }
        if let w = tracker.topWindow(at: p, excluding: excluding), let f = w.frame {
            if let c = groups.containers.container(forChild: w.id) {
                guard !c.children.keys.contains(source.id),
                      let childFrame = c.frame(of: w.id), isMiddle(childFrame, p) else { return nil }
                return .containerTab(c, c.frame)
            }
            if groups.containers.isChild(w.id) { return nil }
            let zone = groups.group(of: w.id)?.frame ?? f
            return isMiddle(zone, p) ? .window(w, zone) : nil
        }
        return nil
    }

    private func setDropTarget(_ target: DropTarget, at p: CGPoint, immediate: Bool) {
        if target.key != dropTarget?.key {
            dropTarget = target
            anchor = p
            since = Date()
            armed = immediate
            if immediate {
                highlight.show(over: target.area, withStrip: target.usesStrip)
            } else {
                highlight.hide()
            }
            return
        }
        dropTarget = target
        if hypot(p.x - anchor.x, p.y - anchor.y) > holdSlop {
            anchor = p
            since = Date()
            if immediate {
                armed = true
                highlight.show(over: target.area, withStrip: target.usesStrip)
            } else if armed {
                armed = false
                highlight.hide()
            }
            return
        }
        if immediate {
            armed = true
            highlight.show(over: target.area, withStrip: target.usesStrip)
        } else if !armed && Date().timeIntervalSince(since) >= holdDuration {
            armed = true
            highlight.show(over: target.area, withStrip: target.usesStrip)
        }
    }

    private func disarm() {
        dropTarget = nil
        armed = false
        highlight.hide()
    }

    private func reset() {
        groups.dragEnded()
        ticker?.invalidate()
        ticker = nil
        source = nil
        sourceStart = nil
        grab = nil
        pressed = nil
        moving = false
        disarm()
    }
}

/// C trampoline for the event tap, which runs on the main run loop.
private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let drags = Unmanaged<DragController>.fromOpaque(refcon).takeUnretainedValue()
    let pass = MainActor.assumeIsolated { drags.handleTap(type, event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}

/// The "let go now and they'll be tabs" hint over the target.
@MainActor
final class DropHighlight {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating

        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 12

        let strip = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: Style.stripHeight))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        strip.layer?.cornerRadius = 9
        strip.autoresizingMask = [.width, .minYMargin]
        v.addSubview(strip)
        panel.contentView = v
    }

    func show(over axRect: CGRect, withStrip: Bool = true) {
        let r = Coords.toAppKit(axRect.insetBy(dx: 6, dy: 6))
        panel.setFrame(r, display: false)
        if let strip = panel.contentView?.subviews.first {
            strip.isHidden = !withStrip
            strip.frame = NSRect(x: 6, y: r.height - Style.stripHeight - 6,
                                 width: r.width - 12, height: Style.stripHeight)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
