import Foundation
import Testing
@testable import IMessage

private let directGUID = "any;-;+12025550123"
private let directHandle = "+12025550123"
private let directText = "synthetic \"direct\" \\ text\n🧪"
private let offlineTarget = ApprovedOSATarget(processIdentifier: 424242, isRunning: { true })
private let smsDirect = ApprovedDirectTarget(threadID: directGUID, identifier: directHandle, serviceName: "SMS",
                                             style: 45, handles: [directHandle])!

@Test func approvedDirectTargetRequiresExactOneToOneChat() {
    func target(_ guid: String = directGUID, identifier: String? = directHandle, service: String? = "SMS",
                style: Int? = 45, handles: [String] = [directHandle]) -> ApprovedDirectTarget? {
        ApprovedDirectTarget(threadID: guid, identifier: identifier, serviceName: service, style: style, handles: handles)
    }
    #expect(target() == smsDirect)
    #expect(target(service: "RCS")?.service == "SMS")
    #expect(target(service: "iMessage")?.service == "iMessage")
    #expect(target("SMS;-;+12025550123")?.service == "SMS")
    #expect(target("iMessage;-;+12025550123", service: "iMessage")?.handle == directHandle)
    for rejected in [
        target(style: 43), target(style: nil), target("any;+;+12025550123"), target("any;-;+12025550124"),
        target("any;-;+12025550123;x"), target("iMessage;-;+12025550123"), target("SMS;-;+12025550123", service: "RCS"),
        target(identifier: nil), target(identifier: ""), target(identifier: "+12025550124"),
        target(service: nil), target(service: "iMessageLite"), target(service: "sms"),
        target(handles: []), target(handles: ["+12025550124"]), target(handles: [directHandle, "+12025550124"]),
    ] { #expect(rejected == nil) }
}

/// Runs the approved program against a stub Messages; no application or Apple events are used.
private func runDirect(
    text: String? = directText, direct: ApprovedDirectTarget? = smsDirect,
    lookup: String = "throw Object.assign(new Error('private'), { errorNumber: -1728 });",
    accounts: String = "[account('SMS', true, '+12025550123'), account('iMessage', true, '+12025550123'), account('RCS', false, '+12025550123')]"
) throws -> (diagnostic: ApprovedSendDiagnostic, lookups: Int, accountReads: Int, sends: Int) {
    var counts = (lookups: 0, accountReads: 0, sends: 0)
    let diagnostic: ApprovedSendDiagnostic
    do {
        diagnostic = try OSA.approvedSend(threadID: directGUID, text: text, direct: direct, permissionCheck: { offlineTarget }, execute: { source, target in
            let program = """
            (() => {
            var lookups = 0, accountReads = 0, sends = 0;
            const expectedText = \(try jsonStringify(directText));
            function account(service, enabled, handle) {
                const participant = { handle: () => handle, service };
                return { serviceType: () => service, enabled: () => enabled,
                         participants: { byName: (name) => name === \(try jsonStringify(directHandle)) ? participant : { handle: () => name } } };
            }
            const stub = {
                running: () => true,
                chats: { byId: (tid) => () => { lookups++; \(lookup) } },
                accounts: () => { accountReads++; return \(accounts); },
                send: (txt, options) => {
                    sends++;
                    if (txt !== expectedText || options.to.service !== 'SMS' || options.to.handle() !== \(try jsonStringify(directHandle)))
                        throw new Error('send arguments were changed');
                }
            };
            function Application(pid) { if (pid !== 424242) throw new Error('target changed'); return stub; }
            const diagnostic = \(source);
            return JSON.stringify({ diagnostic, lookups, accountReads, sends });
            })()
            """
            let result = try OSA.executeApprovedScript(program, target: target, transport: { _, _, _, _ in
                Issue.record("unexpected offline Apple event"); return OSStatus(-1)
            })
            let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            counts = (try #require(object["lookups"] as? Int), try #require(object["accountReads"] as? Int), try #require(object["sends"] as? Int))
            return try #require(object["diagnostic"] as? String)
        })
    } catch let failure as ApprovedSendDiagnostic { diagnostic = failure }
    return (diagnostic, counts.lookups, counts.accountReads, counts.sends)
}

@Test func approvedSendFallsBackOnlyForMissingVerifiedDirectChat() throws {
    let sent = try runDirect()
    #expect(sent.diagnostic.stage == .complete)
    #expect((sent.lookups, sent.accountReads, sent.sends) == (1, 1, 1))
    let probe = try runDirect(text: nil)
    #expect(probe.diagnostic.stage == .complete)
    #expect((probe.lookups, probe.accountReads, probe.sends) == (1, 1, 0))
}

@Test func approvedSendKeepsExactChatWhenLoaded() throws {
    // A loaded chat never consults accounts, and a mismatched chat never falls back.
    let loaded = try runDirect(lookup: "return { id: () => tid, handle: () => \(try jsonStringify(directHandle)), service: 'SMS' };")
    #expect(loaded.diagnostic.stage == .complete)
    #expect((loaded.accountReads, loaded.sends) == (0, 1))
    for lookup in ["return null;", "return { id: () => 'any;-;+12025550124' };"] {
        let result = try runDirect(lookup: lookup)
        #expect(result.diagnostic.stage == .targetLookup)
        #expect((result.accountReads, result.sends) == (0, 0))
    }
}

@Test func approvedSendRefusesUnverifiedFallbacks() throws {
    let unverified = try runDirect(direct: nil)
    #expect(unverified.diagnostic.stage == .targetLookup)
    #expect(unverified.diagnostic.appleEventCode == -1728)
    #expect((unverified.accountReads, unverified.sends) == (0, 0))
    for lookup in ["throw Object.assign(new Error('x'), { errorNumber: -1743 });", "throw {get errorNumber() { throw new Error('x'); }};", "throw null;"] {
        let other = try runDirect(lookup: lookup)
        #expect(other.diagnostic.stage == .targetLookup)
        #expect((other.accountReads, other.sends) == (0, 0))
    }
    for accounts in ["[]", "[account('SMS', false, '+12025550123')]", "[account('iMessage', true, '+12025550123')]",
                     "[account('SMS', true, '+12025550123'), account('SMS', true, '+12025550123')]",
                     "[account('SMS', 'yes', '+12025550123')]"] {
        let result = try runDirect(accounts: accounts)
        #expect(result.diagnostic.stage == .targetLookup)
        #expect(result.sends == 0)
    }
    let renamed = try runDirect(accounts: "[{ serviceType: () => 'SMS', enabled: () => true, participants: { byName: () => ({ handle: () => '+12025550124' }) } }]")
    #expect(renamed.diagnostic.stage == .targetLookup)
    #expect(renamed.sends == 0)
}
