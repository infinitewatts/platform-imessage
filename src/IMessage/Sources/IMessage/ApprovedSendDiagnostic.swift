import AppKit
import Carbon
import IMessagePrivateSPI
import OSAKit

public enum ApprovedSendStage: String, Sendable {
    case permission, targetLookup = "target_lookup", send, script, complete
}

/// Contains only a stage and an explicitly recognized Apple error number, never raw OSA data.
public struct ApprovedSendDiagnostic: Error, Sendable {
    public let stage: ApprovedSendStage
    public let appleEventCode: Int?

    public init(stage: ApprovedSendStage, appleEventCode: Int? = nil) {
        self.stage = stage
        self.appleEventCode = appleEventCode.flatMap { Self.knownCodes.contains($0) ? $0 : nil }
    }

    static let knownCodes = [-600, -609, -1700, -1703, -1708, -1712, -1728, -1743, -1744]

    static func sanitizedNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              knownCodes.contains(where: { Double($0) == number.doubleValue }) else { return nil }
        return number.intValue
    }
}

/// Retains the verified process identity, rather than resolving the app again by path.
struct ApprovedOSATarget {
    let processIdentifier: pid_t
    let isRunning: () -> Bool
}

typealias ApprovedOSATransport = (UnsafePointer<AppleEvent>, UnsafeMutablePointer<AppleEvent>, AESendMode, Int32) -> OSStatus

private final class ApprovedOSASendContext {
    let target: ApprovedOSATarget
    let transport: ApprovedOSATransport
    let observeAddress: (DescType) -> Void

    init(target: ApprovedOSATarget, transport: @escaping ApprovedOSATransport, observeAddress: @escaping (DescType) -> Void) {
        self.target = target
        self.transport = transport
        self.observeAddress = observeAddress
    }
}

extension OSA {
    /// Internal closures provide an offline seam; production uses the same gate and program.
    static func approvedSend(
        threadID: String, text: String?,
        permissionCheck: () throws -> ApprovedOSATarget = approvedSendPermission,
        execute: (String, ApprovedOSATarget) throws -> String = { try executeApprovedScript($0, target: $1) }
    ) throws -> ApprovedSendDiagnostic {
        let target: ApprovedOSATarget
        do { target = try permissionCheck() }
        catch let diagnostic as ApprovedSendDiagnostic { throw diagnostic }
        catch { throw ApprovedSendDiagnostic(stage: .permission) }
        guard !threadID.isEmpty else { throw ApprovedSendDiagnostic(stage: .targetLookup) }
        guard target.processIdentifier > 0, target.isRunning() else {
            throw ApprovedSendDiagnostic(stage: .permission, appleEventCode: -600)
        }
        do {
            let source = try approvedSendScript(threadID: threadID, text: text, processIdentifier: target.processIdentifier)
            let result = try execute(source, target)
            guard let data = result.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stageName = object["stage"] as? String,
                  let stage = ApprovedSendStage(rawValue: stageName) else {
                throw ApprovedSendDiagnostic(stage: .script)
            }
            let code = ApprovedSendDiagnostic.sanitizedNumber(object["appleEventCode"])
            let diagnostic = ApprovedSendDiagnostic(stage: stage, appleEventCode: code)
            guard stage == .complete else { throw diagnostic }
            return diagnostic
        } catch let diagnostic as ApprovedSendDiagnostic { throw diagnostic }
        catch { throw ApprovedSendDiagnostic(stage: .script) }
    }

    private static func approvedSendPermission() throws -> ApprovedOSATarget {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS")
            .first(where: { !$0.isTerminated }) else {
            throw ApprovedSendDiagnostic(stage: .permission, appleEventCode: -600)
        }
        let pid = application.processIdentifier
        guard pid > 0 else { throw ApprovedSendDiagnostic(stage: .permission, appleEventCode: -600) }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let code = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        guard code == noErr else {
            throw ApprovedSendDiagnostic(stage: .permission, appleEventCode: Int(code))
        }
        return ApprovedOSATarget(processIdentifier: pid, isRunning: { !application.isTerminated })
    }

    static func approvedSendScript(threadID: String, text: String?, processIdentifier: pid_t) throws -> String {
        // JSON literals preserve the full GUID and text without service normalization or interpolation.
        let arguments = try jsonStringify([threadID, text])
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return """
        (() => {
            const [tid, txt] = \(arguments);
            let stage = 'script';
            try {
                stage = 'permission';
                const Messages = Application(\(processIdentifier));
                if (!Messages.running()) return JSON.stringify({stage, appleEventCode: -600});
                stage = 'target_lookup';
                const to = Messages.chats.byId(tid)();
                if (!to || to.id() !== tid) return JSON.stringify({stage});
                \(text == nil ? "" : "stage = 'send'; Messages.send(txt, { to });")
                return JSON.stringify({stage: 'complete'});
            } catch (error) {
                let code;
                try {
                    const number = error.errorNumber;
                    if (typeof number === 'number' && Number.isFinite(number) &&
                        \(ApprovedSendDiagnostic.knownCodes).indexOf(number) !== -1) code = number;
                } catch (_) {}
                return JSON.stringify({stage, appleEventCode: code});
            }
        })()
        """
    }

    /// Direct PID-addressed AESendMessage cannot resolve/launch an application by path.
    /// Every event is checked again at this boundary; no default OSA sender or reconnect is used.
    static func sendApprovedAppleEvent(
        _ event: UnsafePointer<AppleEvent>, reply: UnsafeMutablePointer<AppleEvent>,
        mode: AESendMode, timeout: Int32, target: ApprovedOSATarget,
        transport: ApprovedOSATransport, observeAddress: (DescType) -> Void = { _ in }
    ) -> OSStatus {
        guard target.processIdentifier > 0, target.isRunning() else { return OSStatus(procNotFound) }
        var address = AEDesc()
        guard AEGetAttributeDesc(event, AEKeyword(keyAddressAttr), DescType(typeWildCard), &address) == noErr else {
            return OSStatus(errAEWrongDataType)
        }
        defer { AEDisposeDesc(&address) }
        observeAddress(address.descriptorType)
        var pid: pid_t = 0
        switch address.descriptorType {
        case DescType(typeKernelProcessID):
            guard AEGetDescDataSize(&address) == MemoryLayout<pid_t>.size,
                  AEGetDescData(&address, &pid, MemoryLayout<pid_t>.size) == noErr else { return OSStatus(errAEWrongDataType) }
        case DescType(typeProcessSerialNumber):
            // JXA resolves Application(pid) to a PSN. Admit only the same still-running process.
            var psn = ProcessSerialNumber()
            guard AEGetDescDataSize(&address) == MemoryLayout<ProcessSerialNumber>.size,
                  AEGetDescData(&address, &psn, MemoryLayout<ProcessSerialNumber>.size) == noErr else { return OSStatus(errAEWrongDataType) }
            let code = withUnsafePointer(to: &psn) {
                IMPrivateSPIProcessIDForSerialNumber($0, MemoryLayout<ProcessSerialNumber>.size, &pid)
            }
            guard code == noErr else { return OSStatus(code) }
        default: return OSStatus(errAEWrongDataType)
        }
        guard pid == target.processIdentifier else { return OSStatus(errAEWrongDataType) }
        var canonicalEvent = AppleEvent()
        let copyCode = AEDuplicateDesc(event, &canonicalEvent)
        guard copyCode == noErr else { return OSStatus(copyCode) }
        defer { AEDisposeDesc(&canonicalEvent) }
        let canonicalAddress = NSAppleEventDescriptor(processIdentifier: target.processIdentifier)
        let addressCode = AEPutAttributeDesc(&canonicalEvent, AEKeyword(keyAddressAttr), canonicalAddress.aeDesc)
        guard addressCode == noErr else { return OSStatus(addressCode) }
        let safeMode = (mode & ~AESendMode(kAECanInteract | kAEAlwaysInteract | kAECanSwitchLayer)) |
            AESendMode(kAEDoNotPromptForUserConsent | kAENeverInteract | kAEDontReconnect)
        guard target.isRunning() else { return OSStatus(procNotFound) }
        return transport(&canonicalEvent, reply, safeMode, timeout)
    }

    static func executeApprovedScript(
        _ source: String, target: ApprovedOSATarget,
        observeAddress: @escaping (DescType) -> Void = { _ in },
        transport: @escaping ApprovedOSATransport = { AESendMessage($0, $1, $2, Int($3)) }
    ) throws -> String {
        guard target.processIdentifier > 0, target.isRunning() else {
            throw ApprovedSendDiagnostic(stage: .permission, appleEventCode: -600)
        }
        guard let language = OSALanguage(forName: "JavaScript") else { throw ApprovedSendDiagnostic(stage: .script) }
        let instance = OSALanguageInstance(language: language)
        let context = ApprovedOSASendContext(target: target, transport: transport, observeAddress: observeAddress)
        let callback: OSASendUPP = { event, reply, mode, _, timeout, _, _, refcon in
            guard let event, let reply, let refcon else { return OSErr(errAEWrongDataType) }
            let context = Unmanaged<ApprovedOSASendContext>.fromOpaque(refcon).takeUnretainedValue()
            let code = OSA.sendApprovedAppleEvent(event, reply: reply, mode: mode, timeout: timeout,
                                             target: context.target, transport: context.transport, observeAddress: context.observeAddress)
            return OSErr(exactly: code) ?? OSErr(errOSASystemError)
        }
        let code = OSASetSendProc(instance.componentInstance, callback, Unmanaged.passUnretained(context).toOpaque())
        guard code == noErr else { throw ApprovedSendDiagnostic(stage: .script, appleEventCode: Int(code)) }
        defer { _ = OSASetSendProc(instance.componentInstance, nil, nil) }
        let script = OSAScript(source: source, from: nil, languageInstance: instance, using: [])
        var error: NSDictionary?
        let result = withExtendedLifetime(context) { script.executeAndReturnError(&error) }
        // Never copy raw script errors or returned target data into a diagnostic.
        guard error == nil, let value = result?.stringValue else {
            throw ApprovedSendDiagnostic(stage: .script,
                                         appleEventCode: ApprovedSendDiagnostic.sanitizedNumber(error?[OSAScriptErrorNumber]))
        }
        return value
    }
}
