import Foundation

/// Explorer selection has its own focus and range anchor, independent of the
/// document being edited. Paths are kept in visual order by the caller.
public struct ExplorerSelection: Equatable {
    public private(set) var paths = Set<String>()
    public private(set) var focusedPath: String?
    public private(set) var anchorPath: String?

    public init() {}

    public mutating func select(_ path: String?) {
        paths = path.map { [$0] } ?? []
        focusedPath = path; anchorPath = path
    }

    public mutating func selectAll(_ orderedPaths: [String]) {
        paths = Set(orderedPaths)
        focusedPath = orderedPaths.last; anchorPath = orderedPaths.first
    }

    public mutating func toggle(_ path: String) {
        if paths.contains(path) { paths.remove(path) } else { paths.insert(path) }
        focusedPath = path; anchorPath = path
    }

    public mutating func extend(to path: String, in orderedPaths: [String], additive: Bool = false) {
        guard let end = orderedPaths.firstIndex(of: path) else { return }
        let anchor = [anchorPath, focusedPath].compactMap { $0 }.first { orderedPaths.contains($0) } ?? path
        let start = orderedPaths.firstIndex(of: anchor) ?? end
        let range = Set(orderedPaths[min(start, end)...max(start, end)])
        paths = additive ? paths.union(range) : range
        focusedPath = path; anchorPath = anchor
    }

    public mutating func reconcile(with orderedPaths: [String]) {
        let visible = Set(orderedPaths)
        paths.formIntersection(visible)
        if focusedPath.map({ !visible.contains($0) }) ?? true {
            focusedPath = orderedPaths.first { paths.contains($0) }
        }
        if anchorPath.map({ !visible.contains($0) }) ?? true { anchorPath = focusedPath }
    }

    public mutating func remap(_ transform: (String) -> String?) {
        paths = Set(paths.compactMap(transform))
        focusedPath = focusedPath.flatMap(transform)
        anchorPath = anchorPath.flatMap(transform)
    }
}
