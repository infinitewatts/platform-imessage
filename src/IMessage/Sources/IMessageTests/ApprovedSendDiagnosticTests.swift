import Foundation
import Carbon
import Testing
@testable import IMessage

private let exactApprovedGUID = "iMessage;+;fixture-\"\\\n\u{2028}🧪"
private let offlineTarget = ApprovedOSATarget(processIdentifier: 424242, isRunning: { true })

private func evaluateOffline(_ source: String) throws -> String {
    try OSA.executeApprovedScript(source, target: offlineTarget, transport: { _, _, _, _ in
        Issue.record("unexpected offline Apple event"); return OSStatus(errAEEventNotPermitted)
    })
}

private let approvedText = "synthetic \"text\" \\ newline\n\u{2029}🧪"

private func syntheticLiteral(_ value: String) throws -> String {
    try jsonStringify(value).replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}

/// Overrides Application in the JXA context: no real application or Apple events are used.
private func syntheticApprovedScript(
    _ source: String, lookup: String = "return { id: () => tid };",
    send: String = "", running: Bool = true, application: String = "return stub;", prelude: String = ""
) throws -> (diagnostic: String, lookups: Int, sends: Int) {
    let program = """
    \(prelude)
    (() => {
    var lookups = 0, sends = 0;
    const expectedID = \(try syntheticLiteral(exactApprovedGUID));
    const expectedText = \(try syntheticLiteral(approvedText));
    const stub = {
        running: () => \(running),
        chats: { byId: (tid) => () => {
            lookups++;
            if (tid !== expectedID) throw new Error('GUID was changed');
            \(lookup)
        } },
        send: (txt, options) => {
            sends++;
            if (sends !== 1 || txt !== expectedText || options.to.id() !== expectedID)
                throw new Error('send arguments were changed');
            \(send)
        }
    };
    function Application(pid) { if (pid !== 424242) throw new Error('target changed'); \(application) }
    const diagnostic = \(source);
    return JSON.stringify({ diagnostic, lookups, sends });
    })()
    """
    let result = try evaluateOffline(program)
    let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    return (try #require(object["diagnostic"] as? String),
            try #require(object["lookups"] as? Int), try #require(object["sends"] as? Int))
}

@Test func approvedSendDiagnosticNativeJXAMetadata() throws {
    // Native JXA resolution fails offline before any application events or launch.
    let missingApplication = "Application('/__approved_diagnostic_missing_application__.app')"
    let metadata = try evaluateOffline("""
    (() => {
        try { \(missingApplication); }
        catch (error) {
            return JSON.stringify({numberType: typeof error.number,
                                   errorNumberType: typeof error.errorNumber, errorNumber: error.errorNumber});
        }
    })()
    """)
    let object = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
    #expect(object["numberType"] as? String == "undefined")
    #expect(object["errorNumberType"] as? String == "number")
    #expect(object["errorNumber"] as? Int == -2700)
    do {
        _ = try OSA.approvedSend(threadID: exactApprovedGUID, text: nil, permissionCheck: { offlineTarget }, execute: { source, _ in
            // Locally replace Application with a wrapper calling only the deliberately absent path.
            let result = try syntheticApprovedScript(source,
                application: "return nativeApplication('/__approved_diagnostic_missing_application__.app');",
                prelude: "const nativeApplication = Application;")
            #expect(result.lookups == 0)
            #expect(result.sends == 0)
            return result.diagnostic
        })
        Issue.record("native resolution failure completed")
    } catch let diagnostic as ApprovedSendDiagnostic {
        #expect(diagnostic.stage == .permission)
        #expect(diagnostic.appleEventCode == nil)
    }
    let bridge = try approvedDiagnostic(lookup: "ObjC.import('__approved_diagnostic_missing_framework__');")
    #expect(bridge.stage == .targetLookup)
    #expect(bridge.appleEventCode == nil)
    let wrongProperty = try approvedDiagnostic(lookup: "throw {number: -1728};")
    #expect(wrongProperty.stage == .targetLookup)
    #expect(wrongProperty.appleEventCode == nil)
}

private func approvedDiagnostic(
    text: String? = approvedText, lookup: String = "return { id: () => tid };",
    send: String = "", running: Bool = true, application: String = "return stub;",
    expectedLookups: Int = 1, expectedSends: Int = 0
) throws -> ApprovedSendDiagnostic {
    do {
        return try OSA.approvedSend(threadID: exactApprovedGUID, text: text, permissionCheck: { offlineTarget }, execute: { source, _ in
            let result = try syntheticApprovedScript(source, lookup: lookup, send: send, running: running, application: application)
            #expect(result.lookups == expectedLookups)
            #expect(result.sends == expectedSends)
            return result.diagnostic
        })
    } catch let diagnostic as ApprovedSendDiagnostic { return diagnostic }
}

@Test func approvedSendDiagnosticExactGUIDAndJSONEscaping() throws {
    let result = try approvedDiagnostic(expectedSends: 1)
    #expect(result.stage == .complete)
    #expect(result.appleEventCode == nil)
}

@Test func approvedSendDiagnosticProbeNeverSends() throws {
    let result = try approvedDiagnostic(text: nil, send: "throw new Error('probe sent');")
    #expect(result.stage == .complete)
    #expect(result.appleEventCode == nil)
}

@Test func approvedSendDiagnosticLookupAndSendExceptions() throws {
    for code in ApprovedSendDiagnostic.knownCodes {
        let throwing = "throw Object.assign(new Error('private GUID/text must be discarded'), { errorNumber: \(code) });"
        let lookup = try approvedDiagnostic(lookup: throwing)
        #expect(lookup.stage == .targetLookup)
        #expect(lookup.appleEventCode == code)
        let send = try approvedDiagnostic(send: throwing, expectedSends: 1)
        #expect(send.stage == .send)
        #expect(send.appleEventCode == code)
    }
}

@Test func approvedSendDiagnosticRejectsUnknownExceptionNumbers() throws {
    for number in ["123456", "-1728.5", "NaN", "Infinity", "'-1728'", "null", "true", "undefined"] {
        let result = try approvedDiagnostic(send: "throw {errorNumber: \(number), message: 'private'};", expectedSends: 1)
        #expect(result.stage == .send)
        #expect(result.appleEventCode == nil)
    }
    for error in ["null", "'private'", "{get errorNumber() { throw new Error('private'); }}"] {
        let result = try approvedDiagnostic(lookup: "throw \(error);")
        #expect(result.stage == .targetLookup)
        #expect(result.appleEventCode == nil)
    }
}

@Test func approvedSendDiagnosticMissingOrMismatchedTarget() throws {
    for lookup in ["return null;", "return undefined;", "return {};", "return {id: () => 'SMS;+;other'};",
                   "return {id: () => null};", "return {id: () => new String(tid)};"] {
        let result = try approvedDiagnostic(lookup: lookup)
        #expect(result.stage == .targetLookup)
        #expect(result.appleEventCode == nil)
    }
    let result = try approvedDiagnostic(text: nil, lookup: "return {id: () => 'other'};")
    #expect(result.stage == .targetLookup)
}

@Test func approvedSendDiagnosticPermissionShortCircuits() throws {
    for text: String? in [nil, approvedText] {
        for code in [-600, -1743, -1744, 123456] {
            var executed = false
            do {
                _ = try OSA.approvedSend(threadID: exactApprovedGUID, text: text, permissionCheck: {
                    throw ApprovedSendDiagnostic(stage: .permission, appleEventCode: code)
                }, execute: { _, _ in executed = true; return "" })
                Issue.record("denied permission completed")
            } catch let diagnostic as ApprovedSendDiagnostic {
                #expect(diagnostic.stage == .permission)
                #expect(diagnostic.appleEventCode == (code == 123456 ? nil : code))
            }
            #expect(!executed)
        }
    }
    let stopped = try approvedDiagnostic(running: false, expectedLookups: 0)
    #expect(stopped.stage == .permission)
    #expect(stopped.appleEventCode == -600)
}

@Test func approvedSendDiagnosticScriptFailuresAndInvalidInput() throws {
    let result = try approvedDiagnostic(application: "throw {errorNumber: -1708, message: 'private'};", expectedLookups: 0)
    #expect(result.stage == .permission)
    #expect(result.appleEventCode == -1708)
    for value in ["private", "{}", "{\"stage\":\"unknown\"}"] {
        do {
            _ = try OSA.approvedSend(threadID: exactApprovedGUID, text: nil, permissionCheck: { offlineTarget }, execute: { _, _ in value })
            Issue.record("invalid script response completed")
        } catch let diagnostic as ApprovedSendDiagnostic { #expect(diagnostic.stage == .script) }
    }
    do {
        _ = try OSA.approvedSend(threadID: "", text: nil, permissionCheck: { offlineTarget }, execute: { _, _ in
            Issue.record("empty target executed a script"); return ""
        })
        Issue.record("empty target completed")
    } catch let diagnostic as ApprovedSendDiagnostic { #expect(diagnostic.stage == .targetLookup) }
    do {
        _ = try evaluateOffline("this is invalid JavaScript !!!")
        Issue.record("invalid JXA completed")
    } catch let diagnostic as ApprovedSendDiagnostic { #expect(diagnostic.stage == .script) }
}

@Test func approvedSendDiagnosticPublicConstructorSanitizes() {
    for stage in [ApprovedSendStage.permission, .targetLookup, .send, .script, .complete] {
        for code in ApprovedSendDiagnostic.knownCodes {
            #expect(ApprovedSendDiagnostic(stage: stage, appleEventCode: code).appleEventCode == code)
        }
        for code in [0, 123456, Int.min, Int.max] {
            #expect(ApprovedSendDiagnostic(stage: stage, appleEventCode: code).appleEventCode == nil)
        }
    }
}

@Test func approvedSendDiagnosticResponseAndBoundarySanitization() throws {
    for stage in [ApprovedSendStage.permission, .targetLookup, .send, .script] {
        for value in ["-1728", "123456", "-1728.5", "true", "\"-1728\""] {
            do {
                _ = try OSA.approvedSend(threadID: exactApprovedGUID, text: nil, permissionCheck: { offlineTarget }, execute: { _, _ in
                    "{\"stage\":\"\(stage.rawValue)\",\"appleEventCode\":\(value)}"
                })
                Issue.record("failure response completed")
            } catch let diagnostic as ApprovedSendDiagnostic {
                #expect(diagnostic.stage == stage)
                #expect(diagnostic.appleEventCode == (value == "-1728" ? -1728 : nil))
            }
        }
    }
    let privateError = NSError(domain: "synthetic-private-text", code: -1728)
    do {
        _ = try OSA.approvedSend(threadID: exactApprovedGUID, text: nil, permissionCheck: { throw privateError }, execute: { _, _ in
            Issue.record("failed gate executed"); return ""
        })
        Issue.record("failed gate completed")
    } catch let diagnostic as ApprovedSendDiagnostic {
        #expect(diagnostic.stage == .permission)
        #expect(diagnostic.appleEventCode == nil)
    }
    do {
        _ = try OSA.approvedSend(threadID: exactApprovedGUID, text: nil, permissionCheck: { offlineTarget }, execute: { _, _ in throw privateError })
        Issue.record("failed executor completed")
    } catch let diagnostic as ApprovedSendDiagnostic {
        #expect(diagnostic.stage == .script)
        #expect(diagnostic.appleEventCode == nil)
    }
}

@Test func approvedSendDiagnosticPIDBoundaryAndNoPromptFlags() throws {
    let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
        eventID: AEEventID(kAEGetData), targetDescriptor: NSAppleEventDescriptor(processIdentifier: 424242),
        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    var reply = AppleEvent()
    defer { AEDisposeDesc(&reply) }
    let eventPointer = try #require(event.aeDesc)
    var calls = 0
    let transport: ApprovedOSATransport = { _, _, mode, timeout in
        calls += 1
        #expect(mode & AESendMode(kAEDoNotPromptForUserConsent) != 0)
        #expect(mode & AESendMode(kAENeverInteract) != 0)
        #expect(mode & AESendMode(kAEDontReconnect) != 0)
        #expect(mode & AESendMode(kAECanInteract | kAECanSwitchLayer) == 0)
        #expect(mode & AESendMode(kAEWaitReply) == AESendMode(kAEWaitReply))
        #expect(timeout == 123)
        return OSStatus(errAEEventWouldRequireUserConsent)
    }
    let code = OSA.sendApprovedAppleEvent(eventPointer, reply: &reply,
        mode: AESendMode(kAEWaitReply | kAEAlwaysInteract | kAECanSwitchLayer), timeout: 123,
        target: offlineTarget, transport: transport)
    #expect(code == errAEEventWouldRequireUserConsent)
    #expect(calls == 1) // No retry, even when permission is revoked after preflight.

    let stopped = ApprovedOSATarget(processIdentifier: 424242, isRunning: { false })
    #expect(OSA.sendApprovedAppleEvent(eventPointer, reply: &reply, mode: 0, timeout: 123,
        target: stopped, transport: transport) == procNotFound)
    var runningChecks = 0
    let disappearing = ApprovedOSATarget(processIdentifier: 424242, isRunning: {
        runningChecks += 1; return runningChecks == 1
    })
    #expect(OSA.sendApprovedAppleEvent(eventPointer, reply: &reply, mode: 0, timeout: 123,
        target: disappearing, transport: transport) == procNotFound)

    for address in [NSAppleEventDescriptor(processIdentifier: 424243),
                    NSAppleEventDescriptor(descriptorType: DescType(typeApplicationBundleID), data: Data("com.synthetic.absent".utf8)),
                    NSAppleEventDescriptor(string: "/__synthetic_absent__.app")] {
        let different = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEGetData), targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let differentPointer = try #require(different.aeDesc)
        #expect(OSA.sendApprovedAppleEvent(differentPointer, reply: &reply, mode: 0, timeout: 123,
            target: offlineTarget, transport: transport) == errAEWrongDataType)
    }
    #expect(calls == 1) // No bundle/path fallback or replacement PID gets to the transport.

    var invalidPSN = ProcessSerialNumber(highLongOfPSN: UInt32.max, lowLongOfPSN: UInt32.max)
    var otherPSN = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
    for psnData in [withUnsafeBytes(of: &invalidPSN) { Data($0) }, withUnsafeBytes(of: &otherPSN) { Data($0) }, Data([0])] {
        let psnAddress = NSAppleEventDescriptor(descriptorType: DescType(typeProcessSerialNumber), data: psnData)
        let different = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEGetData), targetDescriptor: psnAddress,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let pointer = try #require(different.aeDesc)
        #expect(OSA.sendApprovedAppleEvent(pointer, reply: &reply, mode: 0, timeout: 123,
            target: offlineTarget, transport: transport) != noErr)
    }
    #expect(calls == 1) // Invalid, malformed, or different-process PSNs never reach transport.

    for target in [stopped, ApprovedOSATarget(processIdentifier: -1, isRunning: { true })] {
        do {
            _ = try OSA.executeApprovedScript("throw new Error('must not execute');", target: target, transport: transport)
            Issue.record("stopped process executed")
        } catch let diagnostic as ApprovedSendDiagnostic {
            #expect(diagnostic.stage == .permission)
            #expect(diagnostic.appleEventCode == -600)
        }
    }
    #expect(calls == 1)
}

@Test func approvedSendDiagnosticNativeJXASendBoundaryWiring() throws {
    // An owned, non-UI process in a temporary bundle provides only synthetic terminology.
    // No LaunchServices launch or real AESend transport is used.
    let fixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("approved-osa-fixture-\(UUID().uuidString.lowercased()).app")
    let contents = fixture.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/fixture-runner")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: fixture) }
        catch { Issue.record("synthetic fixture cleanup failed") }
    }
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let source = contents.appendingPathComponent("fixture.swift")
    try """
    import AppKit
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    DispatchQueue.main.async { print("ready"); fflush(stdout) }
    application.run()
    """.write(to: source, atomically: true, encoding: .utf8)
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["swiftc", source.path, "-o", executable.path]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    let info: [String: Any] = ["CFBundleIdentifier": "com.synthetic.approved-osa-fixture",
                             "CFBundleName": "Approved OSA Fixture", "CFBundleExecutable": "fixture-runner",
                             "CFBundlePackageType": "APPL", "NSAppleScriptEnabled": true,
                             "LSBackgroundOnly": true, "LSUIElement": true,
                             "OSAScriptingDefinition": "fixture.sdef"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <dictionary title="Synthetic fixture"><suite name="Fixture" code="fxtr">
    <class name="application" code="capp"><property name="fixture value" code="pfxv" type="text" access="r"/></class>
    </suite></dictionary>
    """.write(to: resources.appendingPathComponent("fixture.sdef"), atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = executable
    let output = Pipe()
    let readySignal = DispatchSemaphore(value: 0)
    output.fileHandleForReading.readabilityHandler = { _ in readySignal.signal() }
    defer { output.fileHandleForReading.readabilityHandler = nil }
    process.standardOutput = output
    try process.run()
    defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    output.fileHandleForWriting.closeFile()
    try #require(readySignal.wait(timeout: .now() + 5) == .success)
    output.fileHandleForReading.readabilityHandler = nil
    let ready = output.fileHandleForReading.availableData
    try #require(String(data: ready, encoding: .utf8) == "ready\n")
    let pid = process.processIdentifier
    let target = ApprovedOSATarget(processIdentifier: pid, isRunning: { process.isRunning })
    var calls = 0
    var addressType: DescType = 0
    let value = try OSA.executeApprovedScript("Application(\(pid)).fixtureValue()", target: target, observeAddress: { addressType = $0 }, transport: { event, reply, mode, _ in
        calls += 1
        var address = AEDesc()
        #expect(AEGetAttributeDesc(event, AEKeyword(keyAddressAttr), DescType(typeWildCard), &address) == noErr)
        defer { AEDisposeDesc(&address) }
        #expect(address.descriptorType == typeKernelProcessID)
        var actualPID: pid_t = 0
        #expect(AEGetDescData(&address, &actualPID, MemoryLayout<pid_t>.size) == noErr)
        #expect(actualPID == pid)
        #expect(mode & AESendMode(kAEDoNotPromptForUserConsent) != 0)
        #expect(mode & AESendMode(kAENeverInteract) != 0)
        #expect(mode & AESendMode(kAEDontReconnect) != 0)
        #expect(mode & AESendMode(kAECanInteract | kAECanSwitchLayer) == 0)
        let response = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        response.setParam(NSAppleEventDescriptor(string: "synthetic reply"), forKeyword: AEKeyword(keyDirectObject))
        guard let descriptor = response.aeDesc else { return OSStatus(errAEWrongDataType) }
        return OSStatus(AEDuplicateDesc(descriptor, reply))
    })
    #expect(calls == 1)
    #expect(addressType == typeProcessSerialNumber)
    #expect(value == "synthetic reply")

    // A controlled native Apple-event failure proves JXA's exception-number property.
    // The status comes from our fake transport, never from a real AESend call.
    for code in [OSStatus(errAEEventWouldRequireUserConsent), OSStatus(-2700)] {
        var failedCalls = 0
        let metadata = try OSA.executeApprovedScript("""
        (() => {
            try { Application(\(pid)).fixtureValue(); return '{}'; }
            catch (error) { return JSON.stringify({errorNumber: error.errorNumber, numberType: typeof error.number}); }
        })()
        """, target: target, transport: { _, _, mode, _ in
            failedCalls += 1
            #expect(mode & AESendMode(kAEDoNotPromptForUserConsent) != 0)
            #expect(mode & AESendMode(kAENeverInteract) != 0)
            #expect(mode & AESendMode(kAEDontReconnect) != 0)
            return code
        })
        let object = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
        #expect(failedCalls == 1)
        #expect(object["errorNumber"] as? Int == Int(code))
        #expect(object["numberType"] as? String == "undefined")
        #expect(ApprovedSendDiagnostic.sanitizedNumber(object["errorNumber"]) == (code == -1744 ? -1744 : nil))
    }
    process.terminate()
    process.waitUntilExit()
    do {
        _ = try OSA.executeApprovedScript("Application(\(pid)).fixtureValue()", target: target, transport: { _, _, _, _ in
            Issue.record("stopped fixture reached transport"); return noErr
        })
        Issue.record("stopped fixture executed")
    } catch let diagnostic as ApprovedSendDiagnostic {
        #expect(diagnostic.stage == .permission)
        #expect(diagnostic.appleEventCode == -600)
    }
}
