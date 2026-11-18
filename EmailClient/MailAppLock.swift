import LocalAuthentication
import Security
import SwiftUI
import UIKit

@MainActor
final class MailAppLock: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var locked = true
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var context: LAContext?
    private var settingAvailable = false
    private var active = false
    private var windowCovers: [UIView] = []

    func coverWindows() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !window.isHidden && !windowCovers.contains(where: { $0.superview === window }) {
                let cover = UIView(frame: window.bounds)
                cover.backgroundColor = .systemBackground
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.accessibilityElementsHidden = true
                window.addSubview(cover)
                windowCovers.append(cover)
            }
        }
    }

    func uncoverWindows() {
        for cover in windowCovers { cover.removeFromSuperview() }
        windowCovers.removeAll()
    }

    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "EmailClient") + ".localLock",
         kSecAttrAccount as String: "enabled",
         kSecAttrSynchronizable as String: false]
    }

    func activate() {
        active = true
        let status = SecItemCopyMatching(key as CFDictionary, nil)
        let wasEnabled = enabled
        switch status {
        case errSecSuccess:
            enabled = true
            if !wasEnabled || !settingAvailable { locked = true }
        case errSecItemNotFound:
            enabled = false
            locked = false
        default:
            settingAvailable = false
            locked = true
            message = "Unlock the iPhone to check your app lock setting."
            return
        }
        settingAvailable = true
    }

    func background() {
        active = false
        context?.invalidate()
        context = nil
        busy = false
        locked = enabled || !settingAvailable
        message = ""
    }

    enum Action { case unlock, enable, disable }

    func authenticate(_ action: Action) async {
        guard active, !busy else { return }
        activate()
        guard settingAvailable else { return }
        switch action {
        case .unlock: guard enabled && locked else { return }
        case .enable: guard !enabled else { return }
        case .disable: guard enabled && !locked else { return }
        }

        let request = LAContext()
        var error: NSError?
        guard request.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Set an iPhone passcode to use app lock."
            return
        }
        context = request
        busy = true
        message = ""
        defer {
            if context === request {
                request.invalidate()
                context = nil
                busy = false
            }
        }
        let reason: String
        switch action {
        case .unlock: reason = "Unlock your mail"
        case .enable: reason = "Turn on the mail app lock"
        case .disable: reason = "Turn off the mail app lock"
        }
        do {
            let success = try await request.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success, active, context === request else { return }
            switch action {
            case .unlock: locked = false
            case .enable:
                var item = key
                item[kSecValueData as String] = Data([1])
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let status = SecItemAdd(item as CFDictionary, nil)
                guard status == errSecSuccess || status == errSecDuplicateItem else { message = "Could not enable app lock."; return }
                enabled = true
                locked = false
            case .disable:
                guard SecItemDelete(key as CFDictionary) == errSecSuccess else { message = "Could not disable app lock."; return }
                enabled = false
            }
        } catch {
            if active, context === request { message = "Authentication ended. Try again when ready." }
        }
    }
}

struct MailLockScreen: View {
    @EnvironmentObject private var lock: MailAppLock
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Mail is locked").font(.title2.bold())
            Button("Unlock Mail") { Task { await lock.authenticate(.unlock) } }
                .buttonStyle(.borderedProminent).disabled(lock.busy)
            if !lock.message.isEmpty { Text(lock.message).font(.footnote) }
        }.padding()
    }
}
