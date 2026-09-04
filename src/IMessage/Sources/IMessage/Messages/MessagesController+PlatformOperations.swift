import Logging
import IMessageCore

private let platformOperationsLog = Logger(imessageLabel: "messages-controller-platform-operations")

extension MessagesController {
    func setReaction(threadID: String, messageID: String, reactionName: String, on: Bool, allowMutationRetries: Bool = true) throws {
        let reaction = if let reaction = Reaction(platformSDKReactionKey: reactionName) {
            // try the "legacy" reactions first (keyed by `supported` in platform info)
            reaction
        } else {
            // assume an emoji itself was passed (beeper desktop)
            reactionName.withoutSkinToneModifiers.first.flatMap(Reaction.init(emoji:))
        }

        guard let reaction else {
            platformOperationsLog.error("couldn't create reaction from provided name: \(reactionName)")
            throw ErrorMessage("Couldn't create reaction from \"\(reactionName)\"")
        }

        let messageCell = try resolveMessageCell(threadID: threadID, platformMessageID: messageID)
        try setReaction(threadID: threadID, messageCell: messageCell, reaction: reaction, on: on, allowMutationRetries: allowMutationRetries)
    }

    func undoSend(threadID: String, messageID: String) throws {
        let messageCell = try resolveMessageCell(threadID: threadID, platformMessageID: messageID)
        try undoSend(threadID: threadID, messageCell: messageCell)
    }

    func editMessage(threadID: String, messageID: String, newText: String, allowMutationRetries: Bool = true) throws {
        let messageCell = try resolveMessageCell(threadID: threadID, platformMessageID: messageID, allowOverlay: false)
        try editMessage(threadID: threadID, messageCell: messageCell, newText: newText, allowMutationRetries: allowMutationRetries)
    }

    func loadAttachment(threadID: String, messageID: String) throws {
        let messageCell = try resolveMessageCell(threadID: threadID, platformMessageID: messageID)
        try loadAttachment(threadID: threadID, messageCell: messageCell)
    }

    func sendMessage(threadID: String, text: String?, filePath: String?, quotedMessageID: String?) throws {
        let quotedMessage: MessageCell? = if let quotedMessageID {
            try resolveMessageCell(threadID: threadID, platformMessageID: quotedMessageID)
        } else {
            nil
        }

        try sendMessage(threadID: threadID, addresses: nil, text: text, filePath: filePath, quotedMessage: quotedMessage)
    }

    private func resolveMessageCell(threadID: String, platformMessageID messageID: String, allowOverlay: Bool = true) throws -> MessageCell {
        let (messageGUID, partIndex) = messageIDParts(fromID: messageID)

        return try resolveMessageCell(
            threadID: threadID,
            messageGUID: messageGUID,
            partIndex: partIndex,
            allowOverlay: allowOverlay
        )
    }
}
