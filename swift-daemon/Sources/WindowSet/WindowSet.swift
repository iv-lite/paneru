// Script-side window tree (`crates/shared_types/windowset.rs`): the
// `paneru.windows(fn)` xmonad-style surface. A `WindowSet` is a predicted
// layout snapshot scripts transform; every transform returns a new value
// (Swift arrays are CoW, so the Rust `Arc` sharing comes free) and appends
// exactly one `LayoutOp` to the replay log — even when the tree cannot
// change (missing window or workspace). `floatAt` appends two, via
// chaining. Equality and encoding ignore the log, like the Rust
// `PartialEq` and `#[serde(skip)]`.
//
// The four bools on `WSWindow` are independent; any combination is legal.
// `WSDisplay`/`WSWorkspace`/`WSColumn` order is normative: iteration runs
// displays, then workspaces, then columns left to right, then floats last.
// New tiled columns always land at width ratio `0.5`.

import Geometry

// MARK: - Frame

/// Global display coordinates, wire-compatible with `state::Frame`.
public struct WSFrame: Equatable, Sendable, Codable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - LayoutOp

/// One replayable layout intent. Serde wire shape is externally tagged
/// snake_case (`{"focus": 1}`, `{"move_to_workspace": {...}}`).
public enum LayoutOp: Equatable, Sendable {
    case focus(WindowID)
    case swap(WindowID, WindowID)
    case moveToWorkspace(window: WindowID, workspace: UInt32, follow: Bool)
    case view(workspace: UInt32)
    case setFloating(window: WindowID, floating: Bool)
    case setManaged(window: WindowID, managed: Bool)
    case setWidth(window: WindowID, ratio: Double)
    case setFrame(window: WindowID, frame: WSFrame)
    case stack(window: WindowID, onto: WindowID, tabs: Bool)
    case unstack(WindowID)

    /// The window the op addresses. `swap` reports only the first;
    /// `stack` the moved window, never `onto`; `view` addresses none.
    public var target: WindowID? {
        switch self {
        case .focus(let w): return w
        case .swap(let first, _): return first
        case .moveToWorkspace(let w, _, _): return w
        case .view: return nil
        case .setFloating(let w, _): return w
        case .setManaged(let w, _): return w
        case .setWidth(let w, _): return w
        case .setFrame(let w, _): return w
        case .stack(let w, _, _): return w
        case .unstack(let w): return w
        }
    }
}

private struct LayoutOpKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    /// Non-failable construction for statically known tags (the failable
    /// protocol initializer stores its input unconditionally, so it cannot
    /// actually fail — this spelling keeps that invariant without `!`).
    init(verbatim stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension LayoutOp: Codable {
    private enum Tag: String {
        case focus, swap
        case moveToWorkspace = "move_to_workspace"
        case view
        case setFloating = "set_floating"
        case setManaged = "set_managed"
        case setWidth = "set_width"
        case setFrame = "set_frame"
        case stack, unstack
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: LayoutOpKey.self)
        switch self {
        case .focus(let w):
            try container.encode(w, forKey: LayoutOpKey(verbatim: Tag.focus.rawValue))
        case .swap(let a, let b):
            try container.encode([a, b], forKey: LayoutOpKey(verbatim: Tag.swap.rawValue))
        case .moveToWorkspace(let w, let ws, let follow):
            struct MoveBody: Encodable { var window: WindowID; var workspace: UInt32; var follow: Bool }
            try container.encode(
                MoveBody(window: w, workspace: ws, follow: follow),
                forKey: LayoutOpKey(verbatim: Tag.moveToWorkspace.rawValue)
            )
        case .view(let ws):
            struct ViewBody: Encodable { var workspace: UInt32 }
            try container.encode(
                ViewBody(workspace: ws),
                forKey: LayoutOpKey(verbatim: Tag.view.rawValue)
            )
        case .setFloating(let w, let floating):
            struct FloatingBody: Encodable { var window: WindowID; var floating: Bool }
            try container.encode(
                FloatingBody(window: w, floating: floating),
                forKey: LayoutOpKey(verbatim: Tag.setFloating.rawValue)
            )
        case .setManaged(let w, let managed):
            struct ManagedBody: Encodable { var window: WindowID; var managed: Bool }
            try container.encode(
                ManagedBody(window: w, managed: managed),
                forKey: LayoutOpKey(verbatim: Tag.setManaged.rawValue)
            )
        case .setWidth(let w, let ratio):
            struct WidthBody: Encodable { var window: WindowID; var ratio: Double }
            try container.encode(
                WidthBody(window: w, ratio: ratio),
                forKey: LayoutOpKey(verbatim: Tag.setWidth.rawValue)
            )
        case .setFrame(let w, let frame):
            struct FrameBody: Encodable { var window: WindowID; var frame: WSFrame }
            try container.encode(
                FrameBody(window: w, frame: frame),
                forKey: LayoutOpKey(verbatim: Tag.setFrame.rawValue)
            )
        case .stack(let w, let onto, let tabs):
            struct StackBody: Encodable { var window: WindowID; var onto: WindowID; var tabs: Bool }
            try container.encode(
                StackBody(window: w, onto: onto, tabs: tabs),
                forKey: LayoutOpKey(verbatim: Tag.stack.rawValue)
            )
        case .unstack(let w):
            try container.encode(w, forKey: LayoutOpKey(verbatim: Tag.unstack.rawValue))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LayoutOpKey.self)
        let keys = Array(container.allKeys)
        guard keys.count == 1, let tag = Tag(rawValue: keys[0].stringValue) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "expected a single-key layout op"
                )
            )
        }
        let key = keys[0]
        switch tag {
        case .focus:
            self = .focus(try container.decode(WindowID.self, forKey: key))
        case .swap:
            let pair = try container.decode([WindowID].self, forKey: key)
            guard pair.count == 2 else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "swap needs exactly two windows"
                    )
                )
            }
            self = .swap(pair[0], pair[1])
        case .moveToWorkspace:
            struct MoveBody: Decodable { var window: WindowID; var workspace: UInt32; var follow: Bool }
            let body = try container.decode(MoveBody.self, forKey: key)
            self = .moveToWorkspace(window: body.window, workspace: body.workspace, follow: body.follow)
        case .view:
            struct ViewBody: Decodable { var workspace: UInt32 }
            self = .view(workspace: try container.decode(ViewBody.self, forKey: key).workspace)
        case .setFloating:
            struct FloatingBody: Decodable { var window: WindowID; var floating: Bool }
            let body = try container.decode(FloatingBody.self, forKey: key)
            self = .setFloating(window: body.window, floating: body.floating)
        case .setManaged:
            struct ManagedBody: Decodable { var window: WindowID; var managed: Bool }
            let body = try container.decode(ManagedBody.self, forKey: key)
            self = .setManaged(window: body.window, managed: body.managed)
        case .setWidth:
            struct WidthBody: Decodable { var window: WindowID; var ratio: Double }
            let body = try container.decode(WidthBody.self, forKey: key)
            self = .setWidth(window: body.window, ratio: body.ratio)
        case .setFrame:
            struct FrameBody: Decodable { var window: WindowID; var frame: WSFrame }
            let body = try container.decode(FrameBody.self, forKey: key)
            self = .setFrame(window: body.window, frame: body.frame)
        case .stack:
            struct StackBody: Decodable { var window: WindowID; var onto: WindowID; var tabs: Bool }
            let body = try container.decode(StackBody.self, forKey: key)
            self = .stack(window: body.window, onto: body.onto, tabs: body.tabs)
        case .unstack:
            self = .unstack(try container.decode(WindowID.self, forKey: key))
        }
    }
}

// MARK: - RelativeRect

/// Display fractions, xmonad `RationalRect` style.
public struct RelativeRect: Equatable, Sendable {
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

    /// Resolve against a display frame: offsets add the display origin,
    /// sizes clamp to at least 1px, non-finite fractions contribute 0,
    /// and extremes saturate at `Int32` bounds.
    public func resolve(display: WSFrame) -> WSFrame {
        func scale(_ fraction: Double, _ extent: Int32) -> Int32 {
            let scaled = fraction * Double(extent)
            guard scaled.isFinite else { return 0 }
            let clamped = min(max(scaled.rounded(), Double(Int32.min)), Double(Int32.max))
            return Int32(clamped)
        }
        return WSFrame(
            x: display.x + scale(x, display.width),
            y: display.y + scale(y, display.height),
            width: max(scale(width, display.width), 1),
            height: max(scale(height, display.height), 1)
        )
    }
}

// MARK: - Tree records

/// One known window.
public struct WSWindow: Equatable, Sendable, Codable {
    public var id: WindowID
    public var appName: String
    public var bundleID: String
    public var title: String
    public var frame: WSFrame?
    public var floating: Bool
    public var managed: Bool
    public var visible: Bool
    public var focused: Bool

    public init(
        id: WindowID, appName: String = "", bundleID: String = "",
        title: String = "", frame: WSFrame? = nil,
        floating: Bool = false, managed: Bool = true,
        visible: Bool = true, focused: Bool = false
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.floating = floating
        self.managed = managed
        self.visible = visible
        self.focused = focused
    }

    private enum CodingKeys: String, CodingKey {
        case id, appName = "app_name", bundleID = "bundle_id"
        case title, frame, floating, managed, visible, focused
    }
}

/// One panel: single window, vertical stack, tab group, or fullscreen.
public struct WSColumn: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case single, stack, tabs, fullscreen
    }

    public var kind: Kind
    public var widthRatio: Double
    public var selected: Int
    public var windows: [WSWindow]

    public init(kind: Kind, widthRatio: Double, selected: Int = 0, windows: [WSWindow]) {
        self.kind = kind
        self.widthRatio = widthRatio
        self.selected = selected
        self.windows = windows
    }

    /// A lone window filling a fresh column at the insertion width.
    public static func single(_ window: WSWindow, _ widthRatio: Double = 0.5) -> WSColumn {
        WSColumn(kind: .single, widthRatio: widthRatio, selected: 0, windows: [window])
    }

    /// The on-top window; an out-of-range `selected` falls back to first.
    public var top: WSWindow? {
        if windows.indices.contains(selected) { return windows[selected] }
        return windows.first
    }

    public func contains(_ id: WindowID) -> Bool {
        windows.contains { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, widthRatio = "width_ratio", selected, windows
    }
}

/// One virtual workspace: an ordered strip plus ordered floats above it.
public struct WSWorkspace: Equatable, Sendable, Codable {
    public var number: UInt32
    public var nativeID: UInt64
    public var active: Bool
    public var columns: [WSColumn]
    public var floating: [WSWindow]

    public init(
        number: UInt32, nativeID: UInt64 = 0, active: Bool = false,
        columns: [WSColumn] = [], floating: [WSWindow] = []
    ) {
        self.number = number
        self.nativeID = nativeID
        self.active = active
        self.columns = columns
        self.floating = floating
    }

    /// Tiled windows column-major, then floats in array order.
    public var windows: [WSWindow] {
        columns.flatMap { $0.windows } + floating
    }

    private enum CodingKeys: String, CodingKey {
        case number, nativeID = "native_id", active, columns, floating
    }
}

/// One physical display with ordered workspaces.
public struct WSDisplay: Equatable, Sendable, Codable {
    public var id: UInt32
    public var frame: WSFrame
    public var active: Bool
    public var workspaces: [WSWorkspace]

    public init(id: UInt32, frame: WSFrame, active: Bool = false, workspaces: [WSWorkspace] = []) {
        self.id = id
        self.frame = frame
        self.active = active
        self.workspaces = workspaces
    }
}

// MARK: - WindowSet

/// Predicted layout snapshot with a replay log. Every transform returns a
/// new value and records its op first, whatever the tree does.
public struct WindowSet: Sendable {
    public var displays: [WSDisplay]
    public var focused: WindowID?
    private var opLog: [LayoutOp] = []

    public init(displays: [WSDisplay] = [], focused: WindowID? = nil) {
        self.displays = displays
        self.focused = focused
    }

    /// The replay log, oldest first.
    public func ops() -> [LayoutOp] { opLog }

    /// Whether any transform ever ran, including no-ops.
    public var isTransformed: Bool { !opLog.isEmpty }

    // MARK: Queries

    public func workspaces() -> [WSWorkspace] {
        displays.flatMap { $0.workspaces }
    }

    public func windows() -> [WSWindow] {
        workspaces().flatMap { $0.windows }
    }

    public func window(_ id: WindowID) -> WSWindow? {
        windows().first { $0.id == id }
    }

    public func workspace(_ number: UInt32) -> WSWorkspace? {
        workspaces().first { $0.number == number }
    }

    /// The active workspace of the active display (else the first
    /// display). Nil with no displays or no active workspace there.
    public func current() -> WSWorkspace? {
        let display = displays.first { $0.active } ?? displays.first
        return display?.workspaces.first { $0.active }
    }

    public func displayOf(_ id: WindowID) -> WSDisplay? {
        displays.first { display in
            display.workspaces.contains { $0.windows.contains { $0.id == id } }
        }
    }

    public func workspaceOf(_ id: WindowID) -> WSWorkspace? {
        workspaces().first { $0.windows.contains { $0.id == id } }
    }

    /// 0-indexed column from the left. Nil for floats and missing windows.
    public func columnOf(_ id: WindowID) -> Int? {
        guard let workspace = workspaceOf(id) else { return nil }
        return workspace.columns.firstIndex { $0.contains(id) }
    }

    /// Top of the neighbouring column, if any. No wrap, no cross-workspace.
    public func neighbour(_ id: WindowID, offset: Int) -> WindowID? {
        guard let workspace = workspaceOf(id),
              let column = columnOf(id)
        else { return nil }
        let target = column + offset
        guard target >= 0,
              workspace.columns.indices.contains(target)
        else { return nil }
        return workspace.columns[target].top?.id
    }

    public func east(_ id: WindowID) -> WindowID? { neighbour(id, offset: 1) }
    public func west(_ id: WindowID) -> WindowID? { neighbour(id, offset: -1) }

    /// Cycle through every window of the workspace (members plus floats),
    /// wrapping both directions with Euclidean modulo.
    public func cycle(_ id: WindowID, offset: Int) -> WindowID? {
        guard let workspace = workspaceOf(id) else { return nil }
        let ids = workspace.windows.map { $0.id }
        guard !ids.isEmpty, let at = ids.firstIndex(of: id) else { return nil }
        let index = ((at + offset) % ids.count + ids.count) % ids.count
        return ids[index]
    }

    public func next(_ id: WindowID) -> WindowID? { cycle(id, offset: 1) }
    public func prev(_ id: WindowID) -> WindowID? { cycle(id, offset: -1) }

    // MARK: Mutation helpers

    private mutating func record(_ op: LayoutOp) {
        opLog.append(op)
    }

    private func workspaceIndex(number: UInt32) -> (display: Int, workspace: Int)? {
        for (di, display) in displays.enumerated() {
            if let wi = display.workspaces.firstIndex(where: { $0.number == number }) {
                return (di, wi)
            }
        }
        return nil
    }

    private func activeWorkspaceIndex() -> (display: Int, workspace: Int)? {
        for (di, display) in displays.enumerated() {
            if let wi = display.workspaces.firstIndex(where: { $0.active }) {
                return (di, wi)
            }
        }
        return nil
    }

    /// Lift a window out, collapsing its source column (`selected` clamps,
    /// a lone remainder goes `single`, an emptied column vanishes). Tiled
    /// searched before floating per workspace, display-major.
    private mutating func takeWindow(_ id: WindowID) -> WSWindow? {
        for di in displays.indices {
            for wi in displays[di].workspaces.indices {
                for ci in displays[di].workspaces[wi].columns.indices {
                    if let at = displays[di].workspaces[wi].columns[ci].windows
                        .firstIndex(where: { $0.id == id })
                    {
                        var column = displays[di].workspaces[wi].columns[ci]
                        let taken = column.windows.remove(at: at)
                        if column.windows.isEmpty {
                            displays[di].workspaces[wi].columns.remove(at: ci)
                        } else {
                            column.selected = min(column.selected, column.windows.count - 1)
                            if column.windows.count == 1 { column.kind = .single }
                            displays[di].workspaces[wi].columns[ci] = column
                        }
                        return taken
                    }
                }
                if let at = displays[di].workspaces[wi].floating
                    .firstIndex(where: { $0.id == id })
                {
                    return displays[di].workspaces[wi].floating.remove(at: at)
                }
            }
        }
        return nil
    }

    private mutating func forEachWindow(_ edit: (inout WSWindow) -> Void) {
        for di in displays.indices {
            for wi in displays[di].workspaces.indices {
                for ci in displays[di].workspaces[wi].columns.indices {
                    for wii in displays[di].workspaces[wi].columns[ci].windows.indices {
                        edit(&displays[di].workspaces[wi].columns[ci].windows[wii])
                    }
                }
                for fi in displays[di].workspaces[wi].floating.indices {
                    edit(&displays[di].workspaces[wi].floating[fi])
                }
            }
        }
    }

    private mutating func forEachColumn(_ edit: (inout WSColumn) -> Void) {
        for di in displays.indices {
            for wi in displays[di].workspaces.indices {
                for ci in displays[di].workspaces[wi].columns.indices {
                    edit(&displays[di].workspaces[wi].columns[ci])
                }
            }
        }
    }

    // MARK: Transforms

    /// Mark one window focused everywhere; the cached field follows even a
    /// missing window.
    public func focus(_ id: WindowID) -> WindowSet {
        var copy = self
        copy.record(.focus(id))
        copy.forEachWindow { $0.focused = ($0.id == id) }
        copy.focused = id
        return copy
    }

    /// Exchange two windows' full payloads at their positions; focus stays
    /// with the slot, never the window. Missing either: tree unchanged.
    public func swap(_ first: WindowID, _ second: WindowID) -> WindowSet {
        var copy = self
        copy.record(.swap(first, second))
        guard let left = copy.window(first), let right = copy.window(second) else { return copy }
        copy.forEachWindow { record in
            if record.id == first {
                let keep = record.focused
                record = right
                record.focused = keep
            } else if record.id == second {
                let keep = record.focused
                record = left
                record.focused = keep
            }
        }
        return copy
    }

    /// Move a window's whole column to another workspace, appending a
    /// `0.5` single. Missing destination or window: tree unchanged.
    public func shift(_ id: WindowID, workspace: UInt32, follow: Bool = false) -> WindowSet {
        var copy = self
        copy.record(.moveToWorkspace(window: id, workspace: workspace, follow: follow))
        guard copy.workspaceIndex(number: workspace) != nil,
              let record = copy.takeWindow(id),
              let (di, wi) = copy.workspaceIndex(number: workspace)
        else { return copy }
        copy.displays[di].workspaces[wi].columns.append(.single(record))
        return copy
    }

    /// Show one workspace on its display, leaving other displays alone.
    public func view(_ number: UInt32) -> WindowSet {
        var copy = self
        copy.record(.view(workspace: number))
        for (di, display) in copy.displays.enumerated() where display.workspaces.contains(where: { $0.number == number }) {
            for wi in copy.displays[di].workspaces.indices {
                copy.displays[di].workspaces[wi].active =
                    copy.displays[di].workspaces[wi].number == number
            }
            break
        }
        return copy
    }

    public func float(_ id: WindowID) -> WindowSet { setFloating(id, floating: true) }
    public func sink(_ id: WindowID) -> WindowSet { setFloating(id, floating: false) }

    private func setFloating(_ id: WindowID, floating: Bool) -> WindowSet {
        var copy = self
        copy.record(.setFloating(window: id, floating: floating))
        guard var record = copy.takeWindow(id) else { return copy }
        record.floating = floating
        // The window stays where it was, modulo which side it sits on —
        // which the model resolves to the first active workspace. With
        // none anywhere the taken window drops out of the predicted tree.
        guard let (di, wi) = copy.activeWorkspaceIndex() else { return copy }
        if floating {
            copy.displays[di].workspaces[wi].floating.append(record)
        } else {
            copy.displays[di].workspaces[wi].columns.append(.single(record))
        }
        return copy
    }

    /// Float onto a display-fraction rect: `SetFloating` then `SetFrame`.
    public func floatAt(_ id: WindowID, rect: RelativeRect) -> WindowSet {
        guard let display = displayOf(id) ?? displays.first(where: { $0.active }) ?? displays.first
        else { return float(id) }
        return float(id).setFrame(id, frame: rect.resolve(display: display.frame))
    }

    /// Store a frame for every matching record (meaningful for floats;
    /// the engine owns tiled geometry, the prediction stores regardless).
    public func setFrame(_ id: WindowID, frame: WSFrame) -> WindowSet {
        var copy = self
        copy.record(.setFrame(window: id, frame: frame))
        copy.forEachWindow { if $0.id == id { $0.frame = frame } }
        return copy
    }

    public func manage(_ id: WindowID) -> WindowSet { setManaged(id, managed: true) }
    public func unmanage(_ id: WindowID) -> WindowSet { setManaged(id, managed: false) }

    private func setManaged(_ id: WindowID, managed: Bool) -> WindowSet {
        var copy = self
        copy.record(.setManaged(window: id, managed: managed))
        copy.forEachWindow { if $0.id == id { $0.managed = managed } }
        return copy
    }

    /// Set a column's width ratio, stored exactly as given (no clamping).
    public func width(_ id: WindowID, ratio: Double) -> WindowSet {
        var copy = self
        copy.record(.setWidth(window: id, ratio: ratio))
        copy.forEachColumn { if $0.contains(id) { $0.widthRatio = ratio } }
        return copy
    }

    public func stack(_ id: WindowID, onto: WindowID) -> WindowSet {
        stackAs(id, onto: onto, tabs: false)
    }

    public func tab(_ id: WindowID, onto: WindowID) -> WindowSet {
        stackAs(id, onto: onto, tabs: true)
    }

    private func stackAs(_ id: WindowID, onto: WindowID, tabs: Bool) -> WindowSet {
        var copy = self
        copy.record(.stack(window: id, onto: onto, tabs: tabs))
        // The destination check runs before the lift, so a missing `onto`
        // never loses the window. A self-stack lifts then finds no
        // destination and drops it, like the Rust original.
        guard copy.window(onto) != nil, let record = copy.takeWindow(id) else { return copy }
        for di in copy.displays.indices {
            for wi in copy.displays[di].workspaces.indices {
                for ci in copy.displays[di].workspaces[wi].columns.indices {
                    if copy.displays[di].workspaces[wi].columns[ci].contains(onto) {
                        copy.displays[di].workspaces[wi].columns[ci].kind = tabs ? .tabs : .stack
                        copy.displays[di].workspaces[wi].columns[ci].windows.append(record)
                        return copy
                    }
                }
            }
        }
        return copy
    }

    /// Lift a window back to a fresh `0.5` single on the active workspace.
    public func unstack(_ id: WindowID) -> WindowSet {
        var copy = self
        copy.record(.unstack(id))
        guard let record = copy.takeWindow(id),
              let (di, wi) = copy.activeWorkspaceIndex()
        else { return copy }
        copy.displays[di].workspaces[wi].columns.append(.single(record))
        return copy
    }
}

extension WindowSet: Equatable {
    /// Layout equality only: however a tree was reached, the log is not
    /// part of it.
    public static func == (lhs: WindowSet, rhs: WindowSet) -> Bool {
        lhs.displays == rhs.displays && lhs.focused == rhs.focused
    }
}

extension WindowSet: Codable {
    private enum CodingKeys: String, CodingKey {
        case displays, focused
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displays, forKey: .displays)
        try container.encodeIfPresent(focused, forKey: .focused)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displays = try container.decodeIfPresent([WSDisplay].self, forKey: .displays) ?? []
        focused = try container.decodeIfPresent(WindowID.self, forKey: .focused)
    }
}
