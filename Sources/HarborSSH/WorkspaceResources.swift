import Foundation

extension FileWorkspace {
    func showPreview(_ document: WorkspaceDocument) {
        visibleDocumentID = document.id
        editorRecency.removeAll { $0 == document.id }; editorRecency.append(document.id)
        scheduleEditorEviction()
    }
    func hidePreview(_ document: WorkspaceDocument) {
        if visibleDocumentID == document.id { visibleDocumentID = nil }
        scheduleEditorEviction()
    }
    private func scheduleEditorEviction() {
        evictionTask?.cancel()
        evictionTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            await self?.trimEditors()
        }
    }
    /// Preserve lightweight text, undo history, selection and scroll state;
    /// retain at most the visible editor and two recently used editors.
    func trimEditors() async {
        let keep = visibleDocumentID == nil ? Set<UUID>() : Set(editorRecency.suffix(3))
        for document in documents where !keep.contains(document.id) {
            guard !Task.isCancelled else { return }
            if let editor = document.editor { _ = await editor.suspend() }
        }
        editorRecency = editorRecency.filter { id in documents.contains { $0.id == id } }
    }
}
