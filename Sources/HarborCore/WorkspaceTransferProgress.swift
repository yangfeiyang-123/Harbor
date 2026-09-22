import Foundation

/// Byte counts are measured at the transport, not estimated from elapsed time.
/// A transfer is committed only after the destination acknowledges the import.
public struct WorkspaceTransferProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case preparing, transferring, finalizing }
    public let phase: Phase
    public let bytes: Int64
    public let total: Int64?
    public init(_ phase: Phase, bytes: Int64 = 0, total: Int64? = nil) {
        self.phase = phase; self.bytes = max(0, bytes); self.total = total
    }
}
public typealias WorkspaceTransferReporter = @Sendable (WorkspaceTransferProgress) -> Void

public struct FileProcessProgress: Sendable {
    public let inputBytes: Int64
    public let outputBytes: Int64
}
