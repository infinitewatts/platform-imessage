import Foundation
import IMDatabase

public enum ApprovedExecutionError: Error {
    case alreadyBootstrapped, invalidTarget, invalidOperation, threadExists
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
    /// The message row's service, such as "iMessage", "SMS" or "RCS".
    public let service: String?

    public init(rowID: Int, messageID: String, threadID: String, text: String?, owned: Bool,
                sent: Bool, error: Int = 0, edited: Int = 0, retracted: Bool = false,
                plainSinglePart: Bool = true, associatedID: String? = nil, associatedType: Int = 0,
                service: String? = nil) {
        self.rowID = rowID; self.messageID = messageID; self.threadID = threadID; self.text = text
        self.owned = owned; self.sent = sent; self.error = error; self.edited = edited
        self.retracted = retracted; self.plainSinglePart = plainSinglePart
        self.associatedID = associatedID; self.associatedType = associatedType; self.service = service
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

/// Before and after a first-time-recipient send. Chats are those whose sole participant is the handle.
public struct ApprovedNewRecipientSnapshot: Sendable {
    public let directChats: [ApprovedDirectChat]
    public let watermark: Int
    /// All outgoing rows after the watermark, including other destinations.
    public let outgoing: [ApprovedMessageEvidence]
    public init(directChats: [ApprovedDirectChat], watermark: Int, outgoing: [ApprovedMessageEvidence]) {
        self.directChats = directChats; self.watermark = watermark; self.outgoing = outgoing
    }
}

extension PlatformAPI {
    /// Proves exact lookup only, never send readiness. Does not launch Messages or request consent.
    public func approvedSendTarget(threadID: String) async throws -> ApprovedSendDiagnostic {
        let direct = await approvedDirectTarget(threadID: threadID)
        return try await Self.onMessagesControllerQueue {
            try OSA.approvedSend(threadID: threadID, text: nil, direct: direct)
        }
    }

    /// Nil unless chat.db proves an exact one-to-one chat with a single matching participant.
    /// A read failure also yields nil, leaving only the exact chat lookup.
    func approvedDirectTarget(threadID: String) async -> ApprovedDirectTarget? {
        try? await runApprovedDBQuery { db in
            guard let chat = try db.approvedChatRow(guid: threadID) else { return nil }
            return ApprovedDirectTarget(threadID: threadID, identifier: chat.identifier, serviceName: chat.serviceName,
                                        style: chat.style, handles: try db.handles(inChatWithGUID: threadID).map(\.id))
        }
    }

    /// Read failures throw: they never mean "no chats".
    public func approvedDirectChats(handle: String) async throws -> [ApprovedDirectChat] {
        try await runApprovedDBQuery { db in
            try db.approvedSoleParticipantChats(handle: handle).map {
                ApprovedDirectChat(guid: $0.guid, style: $0.style, serviceName: $0.serviceName)
            }
        }
    }

    /// Proves only that Messages resolves the first-time recipient's participant; never sends.
    public func approvedNewRecipientTarget(handle: String) async throws -> ApprovedSendDiagnostic {
        let target = try await approvedNewRecipient(handle: handle)
        return try await Self.onMessagesControllerQueue {
            try OSA.approvedSend(threadID: "", text: nil, direct: target, newRecipient: true)
        }
    }

    func approvedNewRecipient(handle: String) async throws -> ApprovedDirectTarget {
        guard ApprovedDirectTarget.isUSNumber(handle) else { throw ApprovedExecutionError.invalidTarget }
        guard let target = ApprovedDirectTarget(newRecipient: handle, existingChats: try await approvedDirectChats(handle: handle)) else {
            throw ApprovedExecutionError.threadExists
        }
        return target
    }

    public func approvedNewRecipientSnapshot(handle: String, sinceRowID: Int? = nil) async throws -> ApprovedNewRecipientSnapshot {
        try await runApprovedDBQuery { db in
            let watermark = try db.lastMessageRowID()
            let chats = try db.approvedSoleParticipantChats(handle: handle).map {
                ApprovedDirectChat(guid: $0.guid, style: $0.style, serviceName: $0.serviceName)
            }
            return ApprovedNewRecipientSnapshot(directChats: chats, watermark: watermark,
                                                outgoing: try Self.approvedOutgoing(db: db, since: sinceRowID))
        }
    }

    /// One first-time-recipient send attempt. chat.db is checked again here, immediately before
    /// dispatch. The caller must authorize, preflight, serialize and confirm; never retry throws.
    public func dispatchApprovedNewRecipientSend(handle: String, text: String) async throws {
        guard !text.isEmpty else { throw ApprovedExecutionError.invalidOperation }
        let target = try await approvedNewRecipient(handle: handle)
        _ = try await Self.onMessagesControllerQueue {
            try OSA.approvedSend(threadID: "", text: text, direct: target, newRecipient: true)
        }
    }

    static func approvedOutgoing(db: IMDatabase, since: Int?) throws -> [ApprovedMessageEvidence] {
        try since.map { since in
            try db.sentMessageIDs(since: since).map { candidate in
                guard let evidence = try approvedEvidence(db: db, guid: candidate.guid) else {
                    throw ApprovedExecutionError.invalidTarget
                }
                return evidence
            }
        } ?? []
    }

    /// Uses raw immutable chat/message GUIDs, never aliases or contact equivalence.
    public func approvedSnapshot(threadID: String, messageID: String?, sinceRowID: Int? = nil) async throws -> ApprovedSnapshot {
        try await runApprovedDBQuery { db in
            let watermark = try db.lastMessageRowID()
            let target = try messageID.flatMap { try Self.approvedEvidence(db: db, guid: $0) }
            let outgoing = try Self.approvedOutgoing(db: db, since: sinceRowID)
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
                                       associatedType: row.associatedMessageType, service: row.service)
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
            // JXA targets the exact chat ID, or only its verified direct participant when
            // Messages has not loaded that chat. Never fall back to another send path.
            let direct = await approvedDirectTarget(threadID: threadID)
            _ = try await Self.onMessagesControllerQueue { try OSA.approvedSend(threadID: threadID, text: text!, direct: direct) }
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
