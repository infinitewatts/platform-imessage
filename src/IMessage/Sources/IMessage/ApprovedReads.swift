import Foundation
import IMDatabase

public struct ApprovedThreadSummary: Sendable {
    public let id: String
    public let title: String?
    public let titleTruncated: Bool
    public let isUnread: Bool
}

public struct ApprovedReadMessage: Sendable {
    public let id: String
    public let threadID: String
    public let text: String?
    public let textTruncated: Bool
    public let isFromMe: Bool
    public let isRead: Bool
    /// Unix seconds, preserving subsecond precision available in Double.
    public let timestamp: Double?
    public let retracted: Bool
    public let plainSinglePart: Bool
}

public struct ApprovedThreadPage: Sendable {
    public let items: [ApprovedThreadSummary]
    public let nextRowID: Int?
}

public struct ApprovedMessagePage: Sendable {
    public let items: [ApprovedReadMessage]
    public let nextRowID: Int?
}

extension PlatformAPI {
    /// Read-only, no contacts, attachments, UI automation or account metadata.
    /// Cursor order is descending database row ID, not activity time.
    public func approvedThreads(beforeRowID: Int? = nil, limit: Int = 20) async throws -> ApprovedThreadPage {
        try Self.validateReadPage(beforeRowID: beforeRowID, limit: limit)
        return try await runApprovedDBQuery { db in
            try Self.readApprovedThreads(db: db, beforeRowID: beforeRowID, limit: limit)
        }
    }

    static func readApprovedThreads(db: IMDatabase, beforeRowID: Int?, limit: Int) throws -> ApprovedThreadPage {
        try validateReadPage(beforeRowID: beforeRowID, limit: limit)
        let rows = try db.approvedThreadRows(beforeRowID: beforeRowID, limit: limit + 1)
        let page = Array(rows.prefix(limit))
        let items = page.map { row in
            let title = Self.boundedReadText(row.title, maximumBytes: 1024)
            return ApprovedThreadSummary(id: row.guid, title: title.text, titleTruncated: title.truncated, isUnread: row.isUnread)
        }
        return ApprovedThreadPage(items: items, nextRowID: rows.count > limit ? page.last?.rowID : nil)
    }

    public func approvedMessages(threadID: String, beforeRowID: Int? = nil, limit: Int = 20) async throws -> ApprovedMessagePage {
        try Self.validateReadPage(beforeRowID: beforeRowID, limit: limit)
        guard !threadID.isEmpty, threadID.utf8.count <= 1024 else { throw ApprovedExecutionError.invalidTarget }
        return try await runApprovedDBQuery { db in
            try Self.readApprovedMessages(db: db, threadID: threadID, beforeRowID: beforeRowID, limit: limit)
        }
    }

    static func readApprovedMessages(db: IMDatabase, threadID: String, beforeRowID: Int?, limit: Int) throws -> ApprovedMessagePage {
        try validateReadPage(beforeRowID: beforeRowID, limit: limit)
        guard try db.mappedChatRowID(guid: threadID) != nil else { throw ApprovedExecutionError.invalidTarget }
        let rows = try db.approvedReadMessageRows(threadID: threadID, beforeRowID: beforeRowID, limit: limit + 1)
        let page = Array(rows.prefix(limit))
        let items = try page.map { row -> ApprovedReadMessage in
            let retracted = (row.dateRetracted ?? 0) > 0 || row.wasDetonated == 1
            let attributed = try row.attributedBody.map { try AttributedBodyDecoder.attributedString(from: $0) }
            let text = attributed?.string ?? row.text
            var plain = text != nil && !text!.contains("\u{fffc}") && row.balloonBundleID == nil && row.associatedMessageType == 0
            if let attributed {
                var range = NSRange()
                let index = attributed.length > 0 ? attributed.attribute(.imPart, at: 0, effectiveRange: &range) as? Int : nil
                plain = plain && index == 0 && range.length == attributed.length
            }
            let body = Self.boundedReadText(retracted ? nil : text, maximumBytes: 8192)
            return ApprovedReadMessage(id: row.guid, threadID: threadID, text: body.text, textTruncated: body.truncated,
                                       isFromMe: row.isFromMe == 1, isRead: row.isRead == 1,
                                       timestamp: row.date.flatMap { $0 > 0 ? Double($0) / 1_000_000_000 + 978_307_200 : nil },
                                       retracted: retracted, plainSinglePart: plain)
        }
        return ApprovedMessagePage(items: items, nextRowID: rows.count > limit ? page.last?.rowID : nil)
    }

    static func validateReadPage(beforeRowID: Int?, limit: Int) throws {
        guard (1...20).contains(limit), beforeRowID.map({ $0 > 0 }) ?? true else { throw ApprovedExecutionError.invalidTarget }
    }

    static func boundedReadText(_ value: String?, maximumBytes: Int) -> (text: String?, truncated: Bool) {
        guard let value else { return (nil, false) }
        guard value.utf8.count > maximumBytes else { return (value, false) }
        // Stop on a scalar boundary without normalizing the original UTF-8 bytes.
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in value.unicodeScalars {
            let width = scalar.utf8.count
            guard bytes + width <= maximumBytes else { break }
            result.append(scalar); bytes += width
        }
        return (String(result), true)
    }
}
