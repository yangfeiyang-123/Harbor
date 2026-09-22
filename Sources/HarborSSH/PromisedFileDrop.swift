import AppKit
import UniformTypeIdentifiers
import HarborCore

/// Owns files materialized by another app until the upload has finished. Never
/// remove the source screenshot or Finder file; only our private staging folder.
final class PreparedWorkspaceDrop {
    let items: [WorkspaceDropItem]
    private let staging: URL
    init(items: [WorkspaceDropItem], staging: URL) { self.items = items; self.staging = staging }
    deinit { try? FileManager.default.removeItem(at: staging) }
}

struct WorkspaceDropPayload {
    let providers: [NSItemProvider]
    let promises: [NSFilePromiseReceiver]
    let nativeItems: [WorkspaceDropItem]
    let image: Data?
    let imageType: UTType?
    var external: Bool { !promises.isEmpty || image != nil || !providers.allSatisfy { $0.hasItemConformingToTypeIdentifier(WorkspaceDropItem.typeIdentifier) } }

    /// Capture the drag pasteboard while the drop callback is still on the
    /// stack. SwiftUI's item providers alone omit AppKit's legacy file promises.
    static func capture(_ providers: [NSItemProvider], pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Self {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(WorkspaceDropItem.typeIdentifier) }) {
            return Self(providers: providers, promises: [], nativeItems: [], image: nil, imageType: nil)
        }
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty { return Self(providers: [], promises: promises, nativeItems: [], image: nil, imageType: nil) }
        if !providers.isEmpty { return Self(providers: providers, promises: [], nativeItems: [], image: nil, imageType: nil) }
        let items = (try? WorkspaceDragDrop.items(from: pasteboard)) ?? []
        if !items.isEmpty { return Self(providers: [], promises: [], nativeItems: items, image: nil, imageType: nil) }
        for (type, uti) in [(NSPasteboard.PasteboardType.png, UTType.png), (.tiff, .tiff)] {
            if let data = pasteboard.data(forType: type) { return Self(providers: [], promises: [], nativeItems: [], image: data, imageType: uti) }
        }
        return Self(providers: [], promises: [], nativeItems: [], image: nil, imageType: nil)
    }

    @MainActor func prepare() async throws -> PreparedWorkspaceDrop {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("harbor-drop-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var items = nativeItems
            for receiver in promises {
                let urls = try await Self.receive(receiver, into: staging)
                for url in urls {
                    guard url.resolvingSymlinksInPath().path.hasPrefix(staging.resolvingSymlinksInPath().path + "/") else {
                        throw WorkspaceError.message("The dropped file is outside its receiving folder.")
                    }
                }
                items += try WorkspaceDropPlan.localItems(urls: urls)
            }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(WorkspaceDropItem.typeIdentifier) {
                    items += try await WorkspaceDragDrop.items(from: [provider]); continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let files = try? await WorkspaceDragDrop.items(from: [provider]), !files.isEmpty {
                    items += files; continue
                }
                guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
                    throw WorkspaceError.message("This app did not provide an accessible file or image.")
                }
                let url = try await Self.receiveImage(provider, type: type, into: staging)
                items += try WorkspaceDropPlan.localItems(urls: [url])
            }
            if let image, let imageType {
                guard image.count <= 128 * 1024 * 1024 else { throw WorkspaceError.message("The dropped image is too large. Save it to a file first.") }
                let url = staging.appendingPathComponent(Self.imageName(nil, type: imageType))
                try image.write(to: url, options: .atomic)
                items += try WorkspaceDropPlan.localItems(urls: [url])
            }
            guard !items.isEmpty else { throw WorkspaceError.message("No files were received from the drag.") }
            return PreparedWorkspaceDrop(items: items, staging: staging)
        } catch { try? fm.removeItem(at: staging); throw error }
    }

    static func imageName(_ suggested: String?, type: UTType) -> String {
        var name = (suggested ?? "Screenshot-" + UUID().uuidString.prefix(8)).components(separatedBy: .controlCharacters).joined()
        name = (name as NSString).lastPathComponent
        if name.isEmpty || name == "." || name == ".." { name = "Screenshot" }
        name = String(name.prefix(180))
        if (name as NSString).pathExtension.isEmpty { name += "." + (type.preferredFilenameExtension ?? "png") }
        return name
    }

    private static func receiveImage(_ provider: NSItemProvider, type: String, into staging: URL) async throws -> URL {
        // Apple's URL is valid only within this callback. Copy it before
        // resuming; otherwise screenshot uploads race the provider's cleanup.
        let folder = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let name = imageName(provider.suggestedName, type: UTType(type) ?? .png)
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? WorkspaceError.message("Unable to receive the screenshot.") }
                    let target = folder.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func receive(_ receiver: NSFilePromiseReceiver, into staging: URL) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.isSuspended = true
            let result = PromiseResults(continuation)
            receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: queue) { url, error in
                result.received(url, error: error)
            }
            // fileNames is populated by receivePromisedFiles, not before it.
            result.remaining = max(1, receiver.fileNames.count)
            queue.isSuspended = false
        }
    }
}

private final class PromiseResults: @unchecked Sendable {
    var remaining = 0
    private var urls: [URL] = []
    private var error: Error?
    private var continuation: CheckedContinuation<[URL], Error>?
    init(_ continuation: CheckedContinuation<[URL], Error>) { self.continuation = continuation }
    func received(_ url: URL, error: Error?) {
        if let error { self.error = self.error ?? error } else { urls.append(url) }
        remaining -= 1
        guard remaining == 0, let continuation else { return }
        self.continuation = nil
        if let error = self.error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: urls) }
    }
}

extension WorkspaceDragDrop {
    static var folderTypes: [String] {
        types + [UTType.image.identifier, UTType.png.identifier, UTType.tiff.identifier] + NSFilePromiseReceiver.readableDraggedTypes
    }
}

extension AppStore {
    func acceptFileDrop(_ payload: WorkspaceDropPayload, into path: String, in workspace: FileWorkspace, copy: Bool) {
        Task {
            var prepared: PreparedWorkspaceDrop?
            await transferEntries([], to: path, in: workspace, move: !copy) {
                let received = try await payload.prepare(); prepared = received; return received.items
            }
            withExtendedLifetime(prepared) {} // Release staging only after the destination has committed.
        }
    }
}
