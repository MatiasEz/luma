import Carbon
import Foundation

extension Notification.Name {
    static let lumaQuickCaptureRequested = Notification.Name("lumaQuickCaptureRequested")
}

final class GlobalShortcutController: @unchecked Sendable {
    static let shared = GlobalShortcutController()

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var registered = false

    private init() {}

    func register() {
        guard !registered else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .lumaQuickCaptureRequested, object: nil)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandler)

        let signature = FourCharCode(0x4C554D41) // LUMA
        var identifier = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        registered = hotKey != nil
    }
}
