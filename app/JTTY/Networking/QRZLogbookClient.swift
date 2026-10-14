import Foundation
import OSLog

private let log = Logger(subsystem: "com.w2asm.jtty", category: "qrz-logbook")

/// Uploads contacts to a QRZ logbook.
///
/// A different service from the XML callsign lookup and a different credential:
/// this one takes a per-logbook API key rather than the account password, and
/// needs an XML-level subscription. See
/// <https://www.qrz.com/docs/logbook/QRZLogbookAPI.html>.
struct QRZLogbookClient: Sendable {

    enum LogbookError: LocalizedError, Equatable {
        case notConfigured
        case rejected(String)
        case duplicate
        case authenticationFailed
        case service(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No QRZ Logbook Key"
            case .rejected: "QRZ Rejected the Contact"
            case .duplicate: "Already in the QRZ Logbook"
            case .authenticationFailed: "QRZ Logbook Key Refused"
            case .service(let message): message
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notConfigured: "Add your logbook API key in Settings. It is on the QRZ logbook's settings page."
            case .rejected(let reason): reason
            case .duplicate: nil
            case .authenticationFailed: "Check the key, and that the account has an XML subscription."
            case .service: "Try again later."
            }
        }
    }

    var baseURL = URL(string: "https://logbook.qrz.com/api")!
    var session: URLSession = .shared

    /// Insert one contact. Returns the QRZ record id.
    @discardableResult
    func insert(_ entry: LogEntry, key: String) async throws -> String? {
        guard !key.isEmpty else { throw LogbookError.notConfigured }

        let response = try await send([
            "KEY": key,
            "ACTION": "INSERT",
            "ADIF": entry.adifRecord,
            // Without this an upload of a contact QRZ already has fails the
            // whole request; with it the existing record is updated, which is
            // what a retry after a dropped connection should do.
            "OPTION": "REPLACE",
        ])

        switch response["RESULT"] {
        case "OK", "REPLACE":
            return response["LOGID"]
        case "AUTH":
            throw LogbookError.authenticationFailed
        case "FAIL":
            let reason = response["REASON"] ?? "QRZ did not say why."
            // QRZ reports a duplicate as a plain failure, which is not an error
            // worth showing the operator — the contact is already logged.
            if reason.lowercased().contains("duplicate") { throw LogbookError.duplicate }
            throw LogbookError.rejected(reason)
        default:
            throw LogbookError.service(response["REASON"] ?? "Unexpected response from QRZ.")
        }
    }

    /// Logbook statistics, used to confirm a key works before it is relied on.
    func status(key: String) async throws -> [String: String] {
        guard !key.isEmpty else { throw LogbookError.notConfigured }
        let response = try await send(["KEY": key, "ACTION": "STATUS"])
        if response["RESULT"] == "AUTH" { throw LogbookError.authenticationFailed }
        return response
    }

    // MARK: - Plumbing

    /// The API is form-encoded in and `&`-separated `key=value` pairs out —
    /// not JSON in either direction.
    private func send(_ parameters: [String: String]) async throws -> [String: String] {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("qrz logbook request failed: \(error.localizedDescription, privacy: .public)")
            throw LogbookError.service(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LogbookError.service("QRZ returned HTTP \(http.statusCode).")
        }
        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    /// `RESULT=OK&LOGID=12345&COUNT=1`.
    ///
    /// Values are percent-encoded but the separators are not, so this splits
    /// before decoding — decoding first would turn an encoded `&` inside a
    /// failure reason into a field separator.
    static func parse(_ body: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            fields[String(name).uppercased()] = value.removingPercentEncoding ?? value
        }
        return fields
    }
}
