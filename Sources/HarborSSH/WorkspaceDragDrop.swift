import AppKit
import SwiftUI
import UniformTypeIdentifiers
import HarborCore

enum WorkspaceDragDrop {
    static let types = [WorkspaceDropItem.typeIdentifier, UTType.fileURL.identifier]
    static func provider(for entry: WorkspaceEntry, profileID: UUID?) -> NSItemProvider {
        provider(for: [entry], profileID: profileID)
    }
    static func provider(for entries: [WorkspaceEntry], profileID: UUID?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = entries.count == 1 ? entries[0].name : "\(entries.count) items"
        let data = try? JSONEncoder().encode(entries.map { WorkspaceDropItem(profileID: profileID, entry: $0) })
        provider.registerDataRepresentation(forTypeIdentifier: WorkspaceDropItem.typeIdentifier, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        if profileID == nil, entries.count == 1, let entry = entries.first {
            let url = URL(fileURLWithPath: entry.path, isDirectory: entry.directory)
            provider.registerObject(url as NSURL, visibility: .all)
        }
        return provider
    }
    static func plan(from providers: [NSItemProvider]) async throws -> WorkspaceDropPlan {
        try await WorkspaceDropPlan(items: items(from: providers))
    }
    static func items(from providers: [NSItemProvider]) async throws -> [WorkspaceDropItem] {
        var items: [WorkspaceDropItem] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(WorkspaceDropItem.typeIdentifier) {
                let data = try await data(from: provider, type: WorkspaceDropItem.typeIdentifier)
                if let group = try? JSONDecoder().decode([WorkspaceDropItem].self, from: data) { items += group }
                else { items.append(try JSONDecoder().decode(WorkspaceDropItem.self, from: data)) }
            } else {
                let data = try await data(from: provider, type: UTType.fileURL.identifier)
                guard let url = URL(dataRepresentation: data, relativeTo: nil) else { throw WorkspaceError.message("Unable to read the dropped file path.") }
                items += try WorkspaceDropPlan.localItems(urls: [url])
            }
        }
        return items
    }
    private static func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data, data.count <= 1_048_576 { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? WorkspaceError.message("Unable to read the dropped item.")) }
            }
        }
    }
}
