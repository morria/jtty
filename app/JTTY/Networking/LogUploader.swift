import Foundation
import OSLog

private let log = Logger(subsystem: "com.w2asm.jtty", category: "upload")

/// Sends logged contacts to QRZ.
///
/// A failed upload marks nothing, so the contact stays pending and is
/// retried later. The local log is the record of record: a contact is never
/// lost because a server was unreachable, which on a phone in the field is
/// the normal case rather than the exception.
actor LogUploader {
    private let key: String?
    private let qrz = QRZLogbookClient()

    init(enabled: Bool, secrets: SecretStore = SecretStore()) {
        key = enabled ? secrets.load(.qrzLogbookKey) : nil
    }

    var isConfigured: Bool { key != nil }

    func upload(_ entry: LogEntry, into logbook: Logbook) async {
        guard let key, !entry.uploadedToQRZ else { return }
        var updated = entry
        do {
            try await qrz.insert(entry, key: key)
            updated.uploadedToQRZ = true
        } catch QRZLogbookClient.LogbookError.duplicate {
            updated.uploadedToQRZ = true
        } catch {
            log.error("QRZ upload of \(entry.callsign, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        await MainActor.run { logbook.update(updated) }
    }

    /// Retry everything outstanding, oldest first.
    func uploadPending(from logbook: Logbook) async {
        guard key != nil else { return }
        let pending = await MainActor.run { logbook.entries.filter { !$0.uploadedToQRZ }.sorted { $0.time < $1.time } }
        for entry in pending { await upload(entry, into: logbook) }
    }
}
