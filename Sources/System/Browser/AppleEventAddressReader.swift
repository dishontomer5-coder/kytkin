// P3-7: The live Apple Event sender (001 §14.7, R3 §1). Thin on purpose: every decision (when, how often, what the
// reply means) is in Core's `AppleEventFallback`. Runs on the AX thread. NEVER compiled into the test target
// (project.yml lists System/Browser files one by one), so no test can send an Apple Event to a real app.
//
// How one send works:
//   1. The target is `NSAppleEventDescriptor(processIdentifier:)`: never a bundle ID, never `tell application`, so a
//      browser that quit can't be launched (the send fails with procNotFound -600).
//   2. A silent permission check first, `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)`. Anything
//      but noErr → no send. So a send can never show the Automation prompt, even if the grant was reset behind
//      Kytkin's back; the prompt comes only from a click (SystemAutomationRequester).
//   3. One raw `core/getd` event for `property P of [property T of] window 1` (the codes come from Core), sent with
//      wait-for-reply, never-interact and a 0.5 s timeout (never the default 2-minute wait).
//   4. The reply's text or boolean goes back to Core, which hands a URL straight to `SiteReader` and drops it.
// Never logs (Browser/ folder, lint rule 2b).

import CoreServices
import Foundation

final class AppleEventAddressReader: AppleEventSending {
    init() {}

    func send(_ path: AppleEventObjectPath, to pid: Int32, timeoutSeconds: Double) -> AppleEventReply {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let permission = SystemAutomationPermission.silentCheck(target)
        guard permission == noErr else { return .failed(AppleEventFailure(status: permission)) }

        let event = NSAppleEventDescriptor(eventClass: Self.code("core"), eventID: Self.code("getd"),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(Self.specifier(path), forKeyword: Self.code("----"))   // keyDirectObject
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeoutSeconds)
        } catch {
            return .failed(AppleEventFailure(status: Int32(truncatingIfNeeded: (error as NSError).code)))
        }
        if let errn = reply.paramDescriptor(forKeyword: Self.code("errn")), errn.int32Value != 0 {
            return .failed(AppleEventFailure(status: errn.int32Value))
        }
        guard let result = reply.paramDescriptor(forKeyword: Self.code("----")) else {
            return .failed(.noSuchObject)
        }
        switch result.descriptorType {
        case Self.code("bool"), Self.code("true"), Self.code("fals"):
            return .flag(result.booleanValue)
        default:
            guard let text = result.stringValue else { return .failed(.other(0)) }
            return .text(text)
        }
    }

    // MARK: - Object specifiers

    private static func code(_ s: String) -> UInt32 { AppleEventObjectPath.code(s) }

    /// `property <property> of [property <tabProperty> of] window 1`.
    private static func specifier(_ path: AppleEventObjectPath) -> NSAppleEventDescriptor {
        let window = object(want: code(path.windowClass), form: code("indx"),
                            data: NSAppleEventDescriptor(int32: 1), from: .null())
        let owner = path.tabProperty.map { property($0, of: window) } ?? window
        return property(path.property, of: owner)
    }

    private static func property(_ fourChars: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object(want: code("prop"), form: code("prop"), data: NSAppleEventDescriptor(typeCode: code(fourChars)),
               from: container)
    }

    private static func object(want: UInt32, form: UInt32, data: NSAppleEventDescriptor,
                               from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj ")) ?? .record()
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: code("want"))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: code("form"))
        spec.setDescriptor(data, forKeyword: code("seld"))
        spec.setDescriptor(container, forKeyword: code("from"))
        return spec
    }
}
