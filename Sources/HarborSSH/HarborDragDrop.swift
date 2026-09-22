import SwiftUI
import AppKit
import HarborCore

enum HarborDragSource: Codable, Equatable {
    case group(UUID, TerminalScope), terminal(UUID, TerminalScope), server(UUID)
    var type: String {
        if case .server = self { return HarborDragItem.serverType }
        return HarborDragItem.terminalType
    }
    var scope: TerminalScope? {
        switch self { case .group(_, let scope), .terminal(_, let scope): return scope; case .server: return nil }
    }
}

struct HarborDragItem: Codable, Equatable {
    static let terminalType = "app.harbor.ssh.terminal-drag"
    static let serverType = "app.harbor.ssh.server-drag"
    let owner: UUID
    let nonce: UUID
    let source: HarborDragSource

    static func read(_ provider: NSItemProvider, type: String) async throws -> Self {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        guard data.count < 4096 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

enum HarborDropTarget: Equatable {
    case group(UUID, TerminalScope), list(UUID, TerminalScope), pane(UUID, TerminalScope), server(UUID)
    var type: String { if case .server = self { return HarborDragItem.serverType }; return HarborDragItem.terminalType }
    var scope: TerminalScope? {
        switch self { case .group(_, let scope), .list(_, let scope), .pane(_, let scope): return scope; case .server: return nil }
    }
    func intent(at point: CGPoint, size: CGSize) -> HarborDropIntent {
        let x = min(max(point.x / max(size.width, 1), 0), 1)
        let y = min(max(point.y / max(size.height, 1), 0), 1)
        switch self {
        case .group:
            if x < 0.23 { return .before }; if x > 0.77 { return .after }
            return .split(.columns, before: false)
        case .list, .server: return y < 0.5 ? .before : .after
        case .pane:
            if min(y, 1 - y) < min(x, 1 - x) { return .split(.rows, before: y < 0.5) }
            return .split(.columns, before: x < 0.5)
        }
    }
}

enum HarborDropIntent: Equatable {
    case before, after, split(TerminalSplitAxis, before: Bool)
}

extension AppStore {
    func dragTitle(_ source: HarborDragSource) -> String {
        switch source {
        case .server(let id): return profiles.first { $0.id == id }?.name ?? "Server"
        case .terminal(let id, _): return sessions.first { $0.id == id }?.tabTitle ?? "Terminal"
        case .group(let id, let scope):
            let group = arrangement(in: scope).groups.first { $0.id == id }
            return group?.title ?? sessions.first { $0.id == group?.sessionIDs.first }?.tabTitle ?? "Terminal Workspace"
        }
    }
    func dragProvider(_ source: HarborDragSource) -> NSItemProvider {
        let item = HarborDragItem(owner: dragOwnerID, nonce: UUID(), source: source)
        activeDrag = item
        dragEndTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            // This timer is installed exclusively on the main run loop below.
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() }
            }
        }
        dragEndTimer = timer; RunLoop.main.add(timer, forMode: .common)
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            if event.type == .leftMouseUp || event.keyCode == 53 {
                DispatchQueue.main.async { self?.endDrag() }
            }
            return event
        }
        let provider = NSItemProvider(); provider.suggestedName = dragTitle(source)
        let data = try? JSONEncoder().encode(item)
        // Private types and process-local visibility keep these gestures out of
        // file drops and shell text input. A fresh nonce rejects stale replays.
        provider.registerDataRepresentation(forTypeIdentifier: source.type, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }
    func endDrag() {
        activeDrag = nil
        dragEndTimer?.invalidate(); dragEndTimer = nil
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor); self.dragEndMonitor = nil }
    }
    func canDrop(_ item: HarborDragItem, on target: HarborDropTarget, intent: HarborDropIntent) -> Bool {
        guard !loading, item.owner == dragOwnerID, activeDrag == item, item.source.scope == target.scope else { return false }
        if case .server(let sourceID) = item.source {
            guard case .server(let targetID) = target, intent == .before || intent == .after else { return false }
            return sourceID != targetID && profiles.contains { $0.id == sourceID } && profiles.contains { $0.id == targetID }
        }
        guard let scope = target.scope else { return false }
        if case .window = scope {} else {
            guard page == .workspace, currentTerminalScope == scope else { return false }
        }
        let layout = arrangement(in: scope)
        let sourceIDs: [UUID]
        switch item.source {
        case .group(let id, _):
            guard let group = layout.groups.first(where: { $0.id == id }) else { return false }
            sourceIDs = group.sessionIDs
        case .terminal(let id, _):
            guard layout.sessionIDs.contains(id) else { return false }; sourceIDs = [id]
        case .server: return false
        }
        guard sourceIDs.allSatisfy({ id in terminalSessions(in: scope).contains { $0.id == id } }) else { return false }
        switch target {
        case .list(let id, _):
            guard case .terminal = item.source else { return false }
            return (intent == .before || intent == .after) && layout.sessionIDs.contains(id) && !sourceIDs.contains(id)
        case .group(let id, _):
            guard let group = layout.groups.first(where: { $0.id == id }) else { return false }
            if case .group(let sourceID, _) = item.source { return sourceID != id }
            if case .split = intent { return !sourceIDs.contains(group.selectedID) }
            return group.sessionIDs.count > 1 || !group.sessionIDs.contains(sourceIDs[0])
        case .pane(let id, _):
            guard case .split = intent else { return false }
            return layout.sessionIDs.contains(id) && !sourceIDs.contains(id)
        case .server: return false
        }
    }

    @discardableResult func applyDrop(_ item: HarborDragItem, on target: HarborDropTarget, intent: HarborDropIntent) -> Bool {
        guard canDrop(item, on: target, intent: intent) else { return false }
        defer { if activeDrag == item { endDrag() } }
        if case .server(let id) = item.source, case .server(let targetID) = target {
            let profile = profiles.remove(at: profiles.firstIndex { $0.id == id }!)
            let index = profiles.firstIndex { $0.id == targetID }! + (intent == .after ? 1 : 0)
            profiles.insert(profile, at: index); save(); return true
        }
        guard let scope = target.scope else { return false }
        var layout = arrangement(in: scope)
        if case .list(let targetID, _) = target, case .terminal(let id, _) = item.source {
            layout.moveSession(id, relativeTo: targetID, after: intent == .after)
            layout.select(id); terminalLayouts[scope] = layout
            if let session = sessions.first(where: { $0.id == id }) { activateTerminal(session, requestFocus: false) }
            return true
        }
        if case .group(let targetID, _) = target, intent == .before || intent == .after {
            let sourceGroup: UUID
            switch item.source {
            case .group(let id, _): sourceGroup = id
            case .terminal(let id, _):
                layout.separate(id); sourceGroup = layout.groups.first { $0.layout.contains(id) }!.id
            case .server: return false
            }
            layout.moveGroup(sourceGroup, relativeTo: targetID, after: intent == .after)
            terminalLayouts[scope] = layout
            if let selected = layout.selectedID, let session = sessions.first(where: { $0.id == selected }) { activateTerminal(session) }
            return true
        }
        guard case .split(let axis, let before) = intent else { return false }
        let targetGroup: UUID, targetSession: UUID
        switch target {
        case .group(let id, _):
            targetGroup = id; targetSession = layout.groups.first { $0.id == id }!.selectedID
        case .pane(let id, _):
            targetSession = id; targetGroup = layout.groups.first { $0.layout.contains(id) }!.id
        default: return false
        }
        // Preserve the destination's title when its first leaf changes.
        if let group = layout.groups.first(where: { $0.id == targetGroup }), group.title == nil {
            layout.setTitle(dragTitle(.group(targetGroup, scope)), for: targetGroup)
        }
        switch item.source {
        case .group(let id, _):
            let pane: UUID? = { if case .pane = target { return targetSession }; return nil }()
            layout.mergeGroup(id, into: targetGroup, axis: axis, before: before, beside: pane)
        case .terminal(let id, _): layout.split(targetSession, adding: id, axis: axis, before: before)
        case .server: return false
        }
        terminalLayouts[scope] = layout
        if let selected = layout.selectedID, let session = sessions.first(where: { $0.id == selected }) { activateTerminal(session) }
        return true
    }
}

private struct HarborDragSourceModifier: ViewModifier {
    @EnvironmentObject var store: AppStore
    let source: HarborDragSource?
    @ViewBuilder func body(content: Content) -> some View {
        if let source {
            content.onDrag { store.dragProvider(source) } preview: {
                Label(store.dragTitle(source), systemImage: source.scope == nil ? "server.rack" : "terminal")
                    .harborFont(12).foregroundStyle(Color.harborForeground).padding(10)
                    .harborGlass(radius: 10, elevated: true)
            }
        } else { content }
    }
}

private struct HarborDropModifier: ViewModifier {
    @EnvironmentObject var store: AppStore
    let target: HarborDropTarget
    var didDrop: (() -> Void)?
    @State private var size = CGSize.zero
    @State private var hint: HarborDropIntent?
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.onAppear { size = geometry.size }.onChange(of: geometry.size) { _, value in size = value }
            }
        }.overlay {
            if let hint, store.activeDrag != nil, NSEvent.pressedMouseButtons & 1 != 0 { HarborDropIndicator(target: target, intent: hint).allowsHitTesting(false) }
        }.onChange(of: store.activeDrag) { _, value in if value == nil { hint = nil } }
        .onDisappear { hint = nil }
        .onDrop(of: [target.type], delegate: HarborDropDelegate(store: store, target: target, size: size, hint: $hint, didDrop: didDrop))
    }
}

private struct HarborDropDelegate: DropDelegate {
    let store: AppStore
    let target: HarborDropTarget
    let size: CGSize
    @Binding var hint: HarborDropIntent?
    let didDrop: (() -> Void)?
    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [target.type]), let item = store.activeDrag else { return false }
        return store.canDrop(item, on: target, intent: target.intent(at: info.location, size: size))
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info); return DropProposal(operation: hint == nil ? .forbidden : .move)
    }
    private func update(_ info: DropInfo) { hint = validateDrop(info: info) ? target.intent(at: info.location, size: size) : nil }
    func dropExited(info: DropInfo) { hint = nil }
    func performDrop(info: DropInfo) -> Bool {
        hint = nil
        guard validateDrop(info: info), let provider = info.itemProviders(for: [target.type]).first else { return false }
        let intent = target.intent(at: info.location, size: size)
        guard let item = store.activeDrag else { return false }
        _ = provider
        if store.applyDrop(item, on: target, intent: intent) { didDrop?() }
        store.endDrag()
        return true
    }
}

private struct HarborDropIndicator: View {
    let target: HarborDropTarget
    let intent: HarborDropIntent
    var body: some View {
        GeometryReader { geometry in
            switch intent {
            case .before, .after:
                let horizontal: Bool = { if case .group = target { return true }; return false }()
                Rectangle().fill(Color.harborFocus)
                    .frame(width: horizontal ? 3 : geometry.size.width, height: horizontal ? geometry.size.height : 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: horizontal ? (intent == .before ? .leading : .trailing) : (intent == .before ? .top : .bottom))
            case .split(let axis, let before):
                let pane: Bool = { if case .pane = target { return true }; return false }()
                RoundedRectangle(cornerRadius: 4).fill(Color.harborFocus.opacity(0.18))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.harborFocus, lineWidth: 2) }
                    .overlay {
                        Label("Combine Split Panes", systemImage: axis == .columns ? "rectangle.split.2x1" : "rectangle.split.1x2")
                            .harborFont(10, weight: .medium).foregroundStyle(Color.harborForeground)
                            .lineLimit(1).minimumScaleFactor(0.7).padding(4)
                    }
                    .frame(width: pane && axis == .columns ? geometry.size.width / 2 : geometry.size.width,
                           height: pane && axis == .rows ? geometry.size.height / 2 : geometry.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: axis == .columns ? (before ? .leading : .trailing) : (before ? .top : .bottom))
            }
        }
    }
}

extension View {
    func harborDragSource(_ source: HarborDragSource?) -> some View { modifier(HarborDragSourceModifier(source: source)) }
    func harborDropTarget(_ target: HarborDropTarget, didDrop: (() -> Void)? = nil) -> some View { modifier(HarborDropModifier(target: target, didDrop: didDrop)) }
}
