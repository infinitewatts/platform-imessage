import Foundation
import IMDatabase

public enum ApprovedExecutionError: Error {
    case alreadyBootstrapped, invalidTarget, invalidOperation
}

/// Evidence is sensitive process-local data. Never log or serialize it to diagnostics.
public struct ApprovedMessageEvidence: Sendable {
    public let rowID: Int
    public let messageID: String
    public let threadID: String
    public let text: String?
    public let owned: Bool
    public let sent: Bool
    public let error: Int
    public let edited: Int
    public let retracted: Bool
    public let plainSinglePart: Bool
    public let associatedID: String?
    public let associatedType: Int

    public init(rowID: Int, messageID: String, threadID: String, text: String?, owned: Bool,
                sent: Bool, error: Int = 0, edited: Int = 0, retracted: Bool = false,
                plainSinglePart: Bool = true, associatedID: String? = nil, associatedType: Int = 0) {
        self.rowID = rowID; self.messageID = messageID; self.threadID = threadID; self.text = text
        self.owned = owned; self.sent = sent; self.error = error; self.edited = edited
        self.retracted = retracted; self.plainSinglePart = plainSinglePart
        self.associatedID = associatedID; self.associatedType = associatedType
    }
}

public struct ApprovedSnapshot: Sendable {
    public let threadExists: Bool
    public let watermark: Int
    public let target: ApprovedMessageEvidence?
    /// All outgoing rows after the watermark, including other destinations.
    public let outgoing: [ApprovedMessageEvidence]
    public init(threadExists: Bool, watermark: Int, target: ApprovedMessageEvidence?, outgoing: [ApprovedMessageEvidence]) {
        self.threadExists = threadExists; self.watermark = watermark; self.target = target; self.outgoing = outgoing
    }
}

extension PlatformAPI {
    /// Proves exact lookup only, never send readiness. Does not launch Messages or request consent.
    public func approvedSendTarget(threadID: String) async throws -> ApprovedSendDiagnostic {
        try await Self.onMessagesControllerQueue {
            try OSA.approvedSend(threadID: threadID, text: nil)
        }
    }

    /// Uses raw immutable chat/message GUIDs, never aliases or contact equivalence.
    public func approvedSnapshot(threadID: String, messageID: String?, sinceRowID: Int? = nil) async throws -> ApprovedSnapshot {
        try await runApprovedDBQuery { db in
            let watermark = try db.lastMessageRowID()
            let target = try messageID.flatMap { try Self.approvedEvidence(db: db, guid: $0) }
            let outgoing: [ApprovedMessageEvidence] = try sinceRowID.map { since in
                try db.sentMessageIDs(since: since).map { candidate in
                    guard let evidence = try Self.approvedEvidence(db: db, guid: candidate.guid) else {
                        throw ApprovedExecutionError.invalidTarget
                    }
                    return evidence
                }
            } ?? []
            return ApprovedSnapshot(threadExists: try db.mappedChatRowID(guid: threadID) != nil,
                                    watermark: watermark, target: target, outgoing: outgoing)
        }
    }

    static func approvedEvidence(db: IMDatabase, guid: String) throws -> ApprovedMessageEvidence? {
        guard messageGUID(fromID: guid) == guid,
              let row = try db.mappedMessageRow(guid: guid),
              let full = try db.message(with: GUID<Message>(stringLiteral: guid), withAttachments: false) else { return nil }
        let message = full.message
        let text = message.attributedBody?.unwrappingSensitiveData().string ?? message.text?.unwrappingSensitiveData()
        let parts = message.parts
        let plainBody = message.attributedBody == nil ? (text != nil && !text!.contains("\u{fffc}")) :
            (parts.count == 1 && parts.first?.index.rawValue == 0 && parts.first?.replacedWithObject == false)
        let plain = plainBody && row.balloonBundleID == nil
        return approvedEvidence(row: row, text: text, sent: message.isSent, plainSinglePart: plain)
    }

    static func approvedEvidence(row: MappedMessageRow, text: String?, sent: Bool, plainSinglePart: Bool) -> ApprovedMessageEvidence {
        ApprovedMessageEvidence(rowID: row.rowID, messageID: row.guid, threadID: row.threadID ?? "",
                                       text: text, owned: row.isFromMe == 1, sent: sent,
                                       error: row.error, edited: row.dateEdited ?? 0,
                                       retracted: (row.dateRetracted ?? 0) > 0 || row.wasDetonated == 1,
                                       plainSinglePart: plainSinglePart, associatedID: row.associatedMessageGUID,
                                       associatedType: row.associatedMessageType)
    }

    /// One mutation attempt. The caller must authorize, preflight, serialize and confirm.
    /// Throws after dispatch are indeterminate; never retry them automatically.
    public func dispatchApprovedOperation(operation: String, threadID: String, messageID: String?,
                                          text: String?, reaction: String?) async throws {
        guard ["send", "edit", "react", "undo-send"].contains(operation),
              !threadID.isEmpty else { throw ApprovedExecutionError.invalidOperation }
        if operation != "send" {
            guard let messageID, !messageID.isEmpty, messageGUID(fromID: messageID) == messageID else {
                throw ApprovedExecutionError.invalidTarget
            }
        }
        if operation == "send" || operation == "edit" {
            guard let text, !text.isEmpty else { throw ApprovedExecutionError.invalidOperation }
        }
        if operation == "react" {
            guard let reaction, ["heart", "like", "dislike", "laugh", "emphasize", "question"].contains(reaction) else {
                throw ApprovedExecutionError.invalidOperation
            }
        }
        if operation == "send" {
            // JXA targets the exact chat ID. Never fall back to another send path.
            _ = try await Self.onMessagesControllerQueue { try OSA.approvedSend(threadID: threadID, text: text!) }
            return
        }
        try await withMessagesController { controller in
            switch operation {
            case "edit":
                try controller.editMessage(threadID: threadID, messageID: messageID! + "_0", newText: text!, allowMutationRetries: false)
            case "react":
                try controller.setReaction(threadID: threadID, messageID: messageID! + "_0", reactionName: reaction!, on: true, allowMutationRetries: false)
            case "undo-send":
                try controller.undoSend(threadID: threadID, messageID: messageID! + "_0")
            default: throw ApprovedExecutionError.invalidOperation
            }
        }
    }
}
