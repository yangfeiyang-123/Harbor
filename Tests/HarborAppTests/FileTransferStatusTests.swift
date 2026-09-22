import XCTest
import HarborCore
@testable import HarborSSH

final class FileTransferStatusTests: XCTestCase {
    @MainActor func testDelayedUpdatesCannotOverwriteNewItemsOrFinishedTransfers() async {
        let suite = "harbor.transfer-status." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let files = FileWorkspace(profile: nil, defaults: prefs)
        files.transfer = FileTransferStatus(destination: "/tmp")
        let original = files.transfer!, report = files.transferReporter(id: original.id, itemID: original.itemID)
        files.transfer?.itemID = UUID()
        report(WorkspaceTransferProgress(.transferring, bytes: 99, total: 100))
        await flushMainQueue()
        XCTAssertEqual(files.transfer?.progress.bytes, 0)
        let current = files.transfer!, currentReport = files.transferReporter(id: current.id, itemID: current.itemID)
        files.transfer?.completed = true
        currentReport(WorkspaceTransferProgress(.transferring, bytes: 99, total: 100))
        await flushMainQueue()
        XCTAssertEqual(files.transfer?.phaseLabel, "Completed")
        XCTAssertEqual(files.transfer?.progress.bytes, 0)
        files.transfer = FileTransferStatus(destination: "/different")
        currentReport(WorkspaceTransferProgress(.finalizing, bytes: 100, total: 100))
        await flushMainQueue()
        XCTAssertEqual(files.transfer?.destination, "/different")
        XCTAssertEqual(files.transfer?.progress.phase, .preparing)
    }

    func testSentBytesAreNotTreatedAsDestinationCompletion() {
        var state = FileTransferStatus(action: "Uploading", destination: "/tmp")
        state.progress = WorkspaceTransferProgress(.finalizing, bytes: 100, total: 100)
        XCTAssertTrue(state.active); XCTAssertFalse(state.completed)
        XCTAssertNil(state.fraction); XCTAssertEqual(state.phaseLabel, "Finishing")
        state.failure = "Remote destination is full"
        XCTAssertFalse(state.active); XCTAssertFalse(state.completed); XCTAssertEqual(state.phaseLabel, "Transfer failed")
    }

    @MainActor private func flushMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}
