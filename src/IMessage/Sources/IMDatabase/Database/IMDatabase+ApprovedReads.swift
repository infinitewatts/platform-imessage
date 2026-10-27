import SQLite

/// Raw attachment columns for one message. Sensitive; never log.
public struct ApprovedAttachmentRow: Sendable, Equatable {
    public let guid: String
    public let filename: String?
    public let transferName: String?
    public let totalBytes: Int
    public let transferState: Int
    public let isOutgoing: Bool
    public let mimeType: String?

    public init(guid: String, filename: String?, transferName: String?, totalBytes: Int,
                transferState: Int, isOutgoing: Bool, mimeType: String?) {
        self.guid = guid; self.filename = filename; self.transferName = transferName
        self.totalBytes = totalBytes; self.transferState = transferState
        self.isOutgoing = isOutgoing; self.mimeType = mimeType
    }
}

public extension IMDatabase {
    /// Read-only join through message_attachment_join, in attachment ROWID order.
    func approvedAttachmentRows(messageRowID: Int) throws -> [ApprovedAttachmentRow] {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT a.guid, a.filename, a.transfer_name, a.total_bytes, a.transfer_state, a.is_outgoing, a.mime_type
        FROM message_attachment_join AS maj
        INNER JOIN attachment AS a ON a.ROWID = maj.attachment_id
        WHERE maj.message_id = ?
        ORDER BY a.ROWID ASC
        """).reset()
        try statement.bind(messageRowID)
        return try statement.mapRowsUntilDone { row in
            ApprovedAttachmentRow(
                guid: try row[0].expect(String.self), filename: try row[1].optionalConverting(String.self),
                transferName: try row[2].optionalConverting(String.self),
                totalBytes: try row[3].optionalConverting(Int.self) ?? 0,
                transferState: try row[4].optionalConverting(Int.self) ?? 0,
                isOutgoing: try row[5].optionalConverting(Int.self) == 1,
                mimeType: try row[6].optionalConverting(String.self))
        }
    }

    /// Stable insertion-order traversal. Fetch at most one lookahead row.
    func approvedThreadRows(beforeRowID: Int?, limit: Int) throws -> [(rowID: Int, guid: String, title: String?, isUnread: Bool)] {
        let statement = try cachedStatement(forEscapedSQL: """
        SELECT c.ROWID, c.guid, c.display_name,
            EXISTS(SELECT 1 FROM chat_message_join j INNER JOIN message m ON m.ROWID = j.message_id
                   WHERE j.chat_id = c.ROWID AND m.is_from_me = 0 AND m.is_read = 0)
        FROM chat c WHERE c.ROWID < ? ORDER BY c.ROWID DESC LIMIT ?
        """).reset()
        try statement.bind(beforeRowID ?? Int.max, max(1, min(limit, 21)))
        return try statement.mapRowsUntilDone { row in
            try (row[0].expect(Int.self), row[1].expect(String.self), row[2].optional(String.self), row[3].looseBool())
        }
    }

    /// Drive the query from exact chat membership, deduplicating before fetching messages.
    func approvedReadMessageRows(threadID: String, beforeRowID: Int?, limit: Int) throws -> [MappedMessageRow] {
        let columns = try tableColumns("message")
        // Deliberately exclude payloadData, attachments and account/contact joins.
        let permitted = ["guid", "text", "attributedBody", "is_from_me", "is_read", "date",
                         "associated_message_type", "balloon_bundle_id", "date_retracted", "was_detonated"]
        let selection = (["m.ROWID AS ROWID"] + permitted.filter { columns.contains($0) }.map { "m.\($0)" }).joined(separator: ", ")
        let statement = try cachedStatement(forEscapedSQL: Self.approvedReadMessageSQL(selection: selection)).reset()
        try statement.bind(threadID, beforeRowID ?? Int.max, max(1, min(limit, 21)))
        return try statement.mapRowsUntilDone(MappedMessageRow.self)
    }
}

extension IMDatabase {
    static func approvedReadMessageSQL(selection: String) -> String {
        """
        SELECT \(selection) FROM (
            SELECT DISTINCT j.message_id FROM chat c
            INNER JOIN chat_message_join j ON j.chat_id = c.ROWID
            WHERE c.guid = ? AND j.message_id < ?
        ) selected
        INNER JOIN message m ON m.ROWID = selected.message_id
        ORDER BY m.ROWID DESC LIMIT ?
        """
    }
}
