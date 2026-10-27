import Foundation
import IMDatabase
import Testing
@testable import IMessage

private let fileGUID = "any;-;+12025550123"
private let fileHandle = "+12025550123"
private let filePathWithQuotes = "/tmp/synthetic \"file\" \\ name\u{2028}🧪.pdf"
private let fileTarget = ApprovedOSATarget(processIdentifier: 424242, isRunning: { true })
private let fileDirect = ApprovedDirectTarget(threadID: fileGUID, identifier: fileHandle, serviceName: "SMS",
                                              style: 45, handles: [fileHandle])!

@Test func approvedFileScriptAlwaysSendsPathAndEscapesIt() throws {
    let source = try OSA.approvedSendScript(threadID: fileGUID, text: nil, direct: fileDirect,
                                            filePath: filePathWithQuotes, processIdentifier: 424242)
    #expect(source.contains("Messages.send(Path(fp), { to });"))
    #expect(!source.contains("Messages.send(txt"))
    #expect(source.contains(try jsonStringify(filePathWithQuotes).replacingOccurrences(of: "\u{2028}", with: "\\u2028")))
    #expect(!source.contains("\u{2028}"))
    // Text mode and probe mode are unchanged.
    let text = try OSA.approvedSendScript(threadID: fileGUID, text: "hi", direct: fileDirect, processIdentifier: 424242)
    #expect(text.contains("Messages.send(txt, { to });") && !text.contains("Path(fp)"))
    let probe = try OSA.approvedSendScript(threadID: fileGUID, text: nil, direct: fileDirect, processIdentifier: 424242)
    #expect(!probe.contains("Messages.send("))
}

@Test func approvedFileScriptRejectsEmptyPathInsteadOfNoOp() throws {
    #expect(throws: ApprovedSendDiagnostic.self) {
        _ = try OSA.approvedSendScript(threadID: fileGUID, text: nil, direct: fileDirect, filePath: "", processIdentifier: 424242)
    }
    var executed = false
    for (path, text, direct, fresh): (String, String?, ApprovedDirectTarget?, Bool) in [
        ("", nil, fileDirect, false), ("relative.pdf", nil, fileDirect, false), (filePathWithQuotes, "hi", fileDirect, false),
        (filePathWithQuotes, nil, nil, false), (filePathWithQuotes, nil, fileDirect, true),
    ] {
        do {
            _ = try OSA.approvedSend(threadID: fresh ? "" : fileGUID, text: text, direct: direct, newRecipient: fresh,
                                     filePath: path, permissionCheck: { fileTarget }, execute: { _, _ in executed = true; return "" })
            Issue.record("expected rejection")
        } catch let diagnostic as ApprovedSendDiagnostic { #expect(diagnostic.stage != .complete) }
    }
    #expect(!executed)
}

/// Runs the generated program against a stub Messages.
private func runFile(path: String = filePathWithQuotes, direct: ApprovedDirectTarget? = fileDirect,
                     lookup: String) throws -> (stage: ApprovedSendStage, sends: Int) {
    var sends = 0
    do {
        let diagnostic = try OSA.approvedSend(threadID: fileGUID, text: nil, direct: direct, filePath: path,
                                              permissionCheck: { fileTarget }, execute: { source, target in
            let program = """
            (() => {
            var sends = 0;
            function Path(p) { return { path: p }; }
            // Accounts and participants would happily send; a file-mode script must never reach them.
            const stub = { running: () => true, accounts: () => [{ serviceType: () => 'SMS', enabled: () => true,
                    participants: { byName: (n) => ({ handle: () => n }) } }], chats: { byId: (tid) => () => { \(lookup) } },
                send: (arg, options) => { sends++; if (arg.path !== \(try jsonStringify(path))) throw new Error('path changed'); } };
            function Application(pid) { return stub; }
            const diagnostic = \(source);
            return JSON.stringify({ diagnostic, sends });
            })()
            """
            let result = try OSA.executeApprovedScript(program, target: target, transport: { _, _, _, _ in OSStatus(-1) })
            let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            sends = try #require(object["sends"] as? Int)
            return try #require(object["diagnostic"] as? String)
        })
        return (diagnostic.stage, sends)
    } catch let failure as ApprovedSendDiagnostic { return (failure.stage, sends) }
}

@Test func approvedFileSendOnlyReachesLoadedOrVerifiedDirectChat() throws {
    let loaded = try runFile(lookup: "return { id: () => tid };")
    #expect(loaded.stage == .complete && loaded.sends == 1)
    let mismatched = try runFile(lookup: "return { id: () => 'other' };")
    #expect(mismatched.stage == .targetLookup && mismatched.sends == 0)
    let unproven = try runFile(direct: nil, lookup: "return { id: () => tid };")
    #expect(unproven.stage == .targetLookup && unproven.sends == 0)
}

@Test func approvedFileScriptHasNoParticipantFallbackAndUnloadedChatSendsNothing() throws {
    let file = try OSA.approvedSendScript(threadID: fileGUID, text: nil, direct: fileDirect,
                                          filePath: filePathWithQuotes, processIdentifier: 424242)
    for forbidden in ["participants", "accounts", "byName", "direct.handle", "enabled()"] { #expect(!file.contains(forbidden)) }
    #expect(file.contains("Messages.chats.byId(tid)()") && file.contains("to.id() !== tid"))
    // Text keeps its documented unloaded-chat fallback unchanged.
    let text = try OSA.approvedSendScript(threadID: fileGUID, text: "hi", direct: fileDirect, processIdentifier: 424242)
    #expect(text.contains("participants.byName(direct.handle)") && text.contains("-1728"))
    let unloaded = try runFile(lookup: "const e = new Error('unloaded'); e.errorNumber = -1728; throw e;")
    #expect(unloaded.stage == .targetLookup && unloaded.sends == 0)
    let absent = try runFile(lookup: "return null;")
    #expect(absent.stage == .targetLookup && absent.sends == 0)
}

@Test func approvedFilePathValidationRejectsBeforeAnyDispatch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("a.txt").path
    let link = directory.appendingPathComponent("link.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: file))
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
    try PlatformAPI.validatedApprovedFilePath(file)
    for rejected in ["", "relative.txt", "./a.txt", link, directory.path, directory.appendingPathComponent("missing").path, "/a\0b"] {
        #expect(throws: ApprovedExecutionError.self) { try PlatformAPI.validatedApprovedFilePath(rejected) }
    }
}

@Test func approvedAttachmentEvidenceMapsRowsAndExpandsHome() throws {
    let fixture = try TahoeChatDatabaseFixture()
    defer { fixture.cleanup() }
    try fixture.insertMessage(rowID: 5)
    try fixture.insertChatJoin(messageRowID: 5)
    try fixture.insertAttachment(rowID: 9, messageRowID: 5, guid: "att-9", filename: "~/Library/Messages/Attachments/ab/a.pdf",
                                 transferName: "a.pdf", totalBytes: 1234, transferState: 5)
    try fixture.database.execute(sqlWithoutEscaping: "UPDATE attachment SET is_outgoing = 1, mime_type = 'application/pdf' WHERE ROWID = 9")
    let rows = try fixture.imDatabase.approvedAttachmentRows(messageRowID: 5)
    let evidence = rows.map { ApprovedAttachmentEvidence(row: $0, home: "/Users/synthetic") }
    #expect(evidence == [ApprovedAttachmentEvidence(
        guid: "att-9", filePath: "/Users/synthetic/Library/Messages/Attachments/ab/a.pdf", transferName: "a.pdf",
        totalBytes: 1234, transferState: 5, isOutgoing: true, mimeType: "application/pdf")])
    #expect(try fixture.imDatabase.approvedAttachmentRows(messageRowID: 6).isEmpty)
    #expect(ApprovedAttachmentEvidence.resolvedPath("relative", home: "/h") == nil)
    #expect(ApprovedAttachmentEvidence.resolvedPath(nil, home: "/h") == nil)
    #expect(ApprovedAttachmentEvidence.resolvedPath("/abs/x", home: "/h") == "/abs/x")
    #expect(PlatformAPI.approvedEvidence(row: try MappedMessageRow(object: ["ROWID": 1, "guid": "g"]), text: nil, sent: true,
                                         plainSinglePart: true).attachments.isEmpty)
}
