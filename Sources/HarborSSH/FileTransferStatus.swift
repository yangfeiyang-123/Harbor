import SwiftUI
import HarborCore

struct FileTransferStatus: Identifiable {
    let id = UUID()
    var itemID = UUID()
    var action = "Preparing"
    var name = "Files"
    var destination: String
    var index = 1
    var count = 1
    var progress = WorkspaceTransferProgress(.preparing)
    var completed = false
    var failure: String?
    var active: Bool { !completed && failure == nil }
    var phaseLabel: String {
        if completed { return "Completed" }
        if failure != nil { return "Transfer failed" }
        switch progress.phase {
        case .preparing: return action == "Receiving" ? "Receiving files" : "Preparing"
        case .transferring: return action
        case .finalizing: return "Finishing"
        }
    }
    var fraction: Double? {
        guard active, progress.phase == .transferring, let total = progress.total, total > 0 else { return nil }
        return min(1, Double(progress.bytes) / Double(total))
    }
    var amount: String {
        guard progress.bytes > 0 || progress.total != nil else { return "" }
        let done = ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)
        if let total = progress.total { return done + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) }
        return done + " received"
    }
    var summary: String {
        let countLabel = fraction.map { "\(Int($0 * 100))%" }
            ?? (active && progress.phase == .transferring && progress.bytes > 0 ? amount : nil)
        return [phaseLabel, count > 1 ? "\(index)/\(count)" : nil, name, countLabel]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

extension FileWorkspace {
    func transferReporter(id: UUID, itemID: UUID) -> WorkspaceTransferReporter {
        { [weak self] progress in
            DispatchQueue.main.async {
                guard let self, self.transfer?.id == id, self.transfer?.itemID == itemID, self.transfer?.active == true else { return }
                self.transfer?.progress = progress
            }
        }
    }
}

/// Remains visible when the explorer is collapsed or a terminal fills the workbench.
struct FileTransferIndicator: View {
    @ObservedObject var workspace: FileWorkspace
    @State private var details = false
    var body: some View {
        if let transfer = workspace.transfer {
            Button { details.toggle() } label: {
                HStack(spacing: 6) {
                    if transfer.active {
                        if let value = transfer.fraction { ProgressView(value: value).frame(width: 70) }
                        else { ProgressView().controlSize(.mini) }
                    } else { Image(systemName: transfer.completed ? "checkmark.circle" : "exclamationmark.triangle") }
                    Text(transfer.summary).lineLimit(1).truncationMode(.middle)
                }
            }.buttonStyle(.plain).frame(maxWidth: 400)
                .accessibilityLabel(transfer.summary + ". " + transfer.amount)
                .help(transfer.summary + "\n" + transfer.amount + "\n" + transfer.destination)
                .popover(isPresented: $details, arrowEdge: .top) {
                    FileTransferDetails(transfer: transfer) { details = false; workspace.transfer = nil }
                }
        }
    }
}

private struct FileTransferDetails: View {
    let transfer: FileTransferStatus
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(transfer.phaseLabel).font(.headline)
                Spacer()
                if !transfer.active { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss transfer") }
            }
            Text(transfer.name).lineLimit(2)
            if transfer.count > 1 { Text("Item \(transfer.index) of \(transfer.count)") }
            if transfer.active {
                if let value = transfer.fraction { ProgressView(value: value) }
                else { ProgressView().controlSize(.small) }
            }
            if !transfer.amount.isEmpty { Text(transfer.amount).monospacedDigit() }
            Text("To: " + transfer.destination).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let failure = transfer.failure { Text(failure).font(.caption).textSelection(.enabled) }
        }.padding(16).frame(width: 320)
    }
}
