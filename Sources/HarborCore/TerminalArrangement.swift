import Foundation

public enum TerminalSplitAxis: String, Codable, Equatable, Sendable { case columns, rows }

public indirect enum TerminalLayout: Codable, Equatable, Sendable {
    case terminal(UUID)
    case split(id: UUID, axis: TerminalSplitAxis, ratio: Double, first: TerminalLayout, second: TerminalLayout)

    public var sessionIDs: [UUID] {
        switch self {
        case .terminal(let id): return [id]
        case .split(_, _, _, let first, let second): return first.sessionIDs + second.sessionIDs
        }
    }
    public func contains(_ id: UUID) -> Bool { sessionIDs.contains(id) }
    public var preferredMinimumHeight: Double {
        switch self {
        case .terminal: return 86
        case .split(_, let axis, _, let first, let second):
            return axis == .rows ? first.preferredMinimumHeight + second.preferredMinimumHeight + 7 : max(first.preferredMinimumHeight, second.preferredMinimumHeight)
        }
    }
    fileprivate func inserting(_ newID: UUID, after target: UUID, axis: TerminalSplitAxis, before: Bool = false) -> TerminalLayout {
        inserting(.terminal(newID), beside: target, axis: axis, before: before)
    }
    fileprivate func inserting(_ subtree: TerminalLayout, beside target: UUID, axis: TerminalSplitAxis, before: Bool) -> TerminalLayout {
        switch self {
        case .terminal(let id):
            return id == target ? .split(id: UUID(), axis: axis, ratio: 0.5,
                first: before ? subtree : self, second: before ? self : subtree) : self
        case .split(let id, let direction, let ratio, let first, let second):
            return .split(id: id, axis: direction, ratio: ratio,
                          first: first.inserting(subtree, beside: target, axis: axis, before: before), second: second.inserting(subtree, beside: target, axis: axis, before: before))
        }
    }
    fileprivate func removing(_ target: UUID) -> TerminalLayout? {
        switch self {
        case .terminal(let id): return id == target ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            let a = first.removing(target), b = second.removing(target)
            if let a, let b { return .split(id: id, axis: axis, ratio: ratio, first: a, second: b) }
            return a ?? b
        }
    }
    fileprivate func resizing(_ target: UUID, ratio: Double) -> TerminalLayout {
        switch self {
        case .terminal: return self
        case .split(let id, let axis, let current, let first, let second):
            return .split(id: id, axis: axis, ratio: id == target ? min(max(ratio.isFinite ? ratio : 0.5, 0.05), 0.95) : current,
                          first: first.resizing(target, ratio: ratio), second: second.resizing(target, ratio: ratio))
        }
    }
    fileprivate func replacing(_ oldID: UUID, with newID: UUID) -> TerminalLayout {
        switch self {
        case .terminal(let id): return .terminal(id == oldID ? newID : id)
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio, first: first.replacing(oldID, with: newID), second: second.replacing(oldID, with: newID))
        }
    }
}

/// A tab owns a tree, a stable identity and its last focused pane. Its identity
/// survives splitting, closing the original pane and reconnecting a session.
public struct TerminalGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public fileprivate(set) var layout: TerminalLayout
    public fileprivate(set) var selectedID: UUID
    public fileprivate(set) var title: String?
    public fileprivate(set) var tabWidth: Double?
    public var sessionIDs: [UUID] { layout.sessionIDs }
}

public struct TerminalArrangement: Codable, Equatable, Sendable {
    public private(set) var groups: [TerminalGroup] = []
    public private(set) var selectedID: UUID?
    /// List order is independent of the split tree: rearranging editor rows
    /// must not move processes into different panes or discard their ratios.
    public private(set) var sessionIDs: [UUID] = []
    public init() {}
    public var roots: [TerminalLayout] { groups.map(\.layout) }
    public var selectedGroup: TerminalGroup? { selectedID.flatMap { selected in groups.first { $0.layout.contains(selected) } } ?? groups.first }
    public var visible: TerminalLayout? { selectedGroup?.layout }
    public mutating func insert(_ id: UUID) {
        guard !sessionIDs.contains(id) else { select(id); return }
        groups.append(TerminalGroup(id: UUID(), layout: .terminal(id), selectedID: id)); selectedID = id
        sessionIDs.append(id)
    }
    public mutating func select(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.layout.contains(id) }) else { return }
        groups[index].selectedID = id; selectedID = id
    }
    public mutating func selectGroup(_ id: UUID) {
        if let group = groups.first(where: { $0.id == id }) { select(group.selectedID) }
    }
    public mutating func setTitle(_ title: String?, for groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].title = title
    }
    public mutating func setTabWidth(_ width: Double, for groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }), width.isFinite else { return }
        groups[index].tabWidth = min(max(width, 40), 360)
    }
    @discardableResult public mutating func split(_ target: UUID, adding newID: UUID, axis: TerminalSplitAxis, before: Bool = false) -> Bool {
        guard target != newID, sessionIDs.contains(target) else { return false }
        // A newly created terminal may already have been registered as a tab.
        if sessionIDs.contains(newID) { remove(newID) }
        guard let index = groups.firstIndex(where: { $0.layout.contains(target) }) else { return false }
        groups[index].layout = groups[index].layout.inserting(newID, after: target, axis: axis, before: before)
        let position = sessionIDs.firstIndex(of: target)!
        sessionIDs.insert(newID, at: position + (before ? 0 : 1))
        select(newID); return true
    }
    public mutating func remove(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.layout.contains(id) }) else { return }
        sessionIDs.removeAll { $0 == id }
        let oldGroup = groups[index]
        if let remaining = oldGroup.layout.removing(id) {
            groups[index].layout = remaining
            if oldGroup.selectedID == id {
                let position = oldGroup.sessionIDs.firstIndex(of: id) ?? 0
                groups[index].selectedID = remaining.sessionIDs[min(position, remaining.sessionIDs.count - 1)]
            }
            if selectedID == id { selectedID = groups[index].selectedID }
        } else {
            groups.remove(at: index)
            if selectedID == id { selectedID = groups.isEmpty ? nil : groups[min(index, groups.count - 1)].selectedID }
        }
    }
    public mutating func resize(_ splitID: UUID, ratio: Double) {
        for index in groups.indices { groups[index].layout = groups[index].layout.resizing(splitID, ratio: ratio) }
    }
    public mutating func replace(_ oldID: UUID, with newID: UUID) {
        guard sessionIDs.contains(oldID), oldID != newID else { return }
        if sessionIDs.contains(newID) { remove(newID) }
        if let index = sessionIDs.firstIndex(of: oldID) { sessionIDs[index] = newID }
        for index in groups.indices {
            groups[index].layout = groups[index].layout.replacing(oldID, with: newID)
            if groups[index].selectedID == oldID { groups[index].selectedID = newID }
        }
        if selectedID == oldID { selectedID = newID }
    }
    public mutating func separate(_ id: UUID) {
        guard let group = groups.first(where: { $0.layout.contains(id) }), group.sessionIDs.count > 1 else { select(id); return }
        remove(id); insert(id)
    }

    @discardableResult public mutating func moveSession(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, sessionIDs.contains(id), sessionIDs.contains(target) else { return false }
        let previous = sessionIDs
        sessionIDs.removeAll { $0 == id }
        sessionIDs.insert(id, at: sessionIDs.firstIndex(of: target)! + (after ? 1 : 0))
        // A group's first occurrence determines its tab position. Interleaving
        // editor rows is allowed; membership and the spatial layout stay intact.
        let order = sessionIDs
        groups.sort { a, b in
            order.firstIndex(where: { a.layout.contains($0) })! < order.firstIndex(where: { b.layout.contains($0) })!
        }
        return previous != sessionIDs
    }

    @discardableResult public mutating func moveGroup(_ id: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard id != target, let source = groups.firstIndex(where: { $0.id == id }), groups.contains(where: { $0.id == target }) else { return false }
        let previous = groups.map(\.id)
        let group = groups.remove(at: source)
        groups.insert(group, at: groups.firstIndex(where: { $0.id == target })! + (after ? 1 : 0))
        guard previous != groups.map(\.id) else { return false }
        orderSessionsByGroup()
        return true
    }

    /// Merge entire trees, preserving each tree's split IDs and proportions.
    /// The destination tab survives and the dragged group's active pane wins.
    @discardableResult public mutating func mergeGroup(_ id: UUID, into target: UUID, axis: TerminalSplitAxis, before: Bool = false, beside pane: UUID? = nil) -> Bool {
        guard id != target, let source = groups.first(where: { $0.id == id }), let destinationGroup = groups.first(where: { $0.id == target }),
              pane == nil || destinationGroup.layout.contains(pane!) else { return false }
        groups.removeAll { $0.id == id }
        let index = groups.firstIndex(where: { $0.id == target })!
        let destination = groups[index].layout
        if let pane { groups[index].layout = destination.inserting(source.layout, beside: pane, axis: axis, before: before) }
        else {
            groups[index].layout = .split(id: UUID(), axis: axis, ratio: 0.5,
                first: before ? source.layout : destination, second: before ? destination : source.layout)
        }
        groups[index].selectedID = source.selectedID; selectedID = source.selectedID
        let sourceOrder = sessionIDs.filter { source.layout.contains($0) }
        sessionIDs.removeAll { source.layout.contains($0) }
        let insertion = pane.map { sessionIDs.firstIndex(of: $0)! + (before ? 0 : 1) } ??
            (before ? sessionIDs.firstIndex(where: { destination.contains($0) })! : sessionIDs.lastIndex(where: { destination.contains($0) })! + 1)
        sessionIDs.insert(contentsOf: sourceOrder, at: insertion)
        orderSessionsByGroup()
        return true
    }

    private mutating func orderSessionsByGroup() {
        let previous = sessionIDs
        sessionIDs = groups.flatMap { group in previous.filter { group.layout.contains($0) } }
    }
}
