import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        List {
                            ForEach(store.snapshot.accounts) { account in
                                NavigationLink { AccountEditor(account: account) } label: { VStack(alignment: .leading) { Text(account.name); Text(account.address).font(.caption).foregroundStyle(.secondary) } }
                            }
                            NavigationLink("Outlook.com identity check") { OutlookIdentityView() }
                            Section("Groups") { ForEach(store.snapshot.groups, id: \.self) { Text($0) }; Text("Add groups from the Accounts menu.").font(.caption).foregroundStyle(.secondary) }
                        }.navigationTitle("Accounts & groups")
                    } label: { Label("Accounts & groups", systemImage: "person.crop.rectangle.stack") }
                    NavigationLink {
                        Form {
                            Toggle("Show full sender address", isOn: $store.snapshot.preferences.showSenderAddress)
                            Picker("Mailbox label", selection: $store.snapshot.preferences.mailboxLabel) { ForEach(["Address", "Name", "Hidden"], id: \.self) { Text($0).tag($0) } }
                            Text("All includes both Priority and other inbox messages. Junk is a separate folder. Sorting in this prototype uses sample labels.").font(.caption).foregroundStyle(.secondary)
                        }.navigationTitle("Mail")
                    } label: { Label("Mail", systemImage: "envelope") }
                    NavigationLink {
                        Form {
                            Picker("Appearance", selection: $store.snapshot.preferences.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0).tag($0) } }
                            Text("Native controls support Dynamic Type and the iOS Reduce Motion setting. Set a local reminder from a message in your follow-ups. New-mail alerts require a connected provider.").font(.caption).foregroundStyle(.secondary)
                        }.navigationTitle("Appearance & alerts")
                    } label: { Label("Appearance & alerts", systemImage: "paintpalette") }
                    NavigationLink { SecurityView() } label: { Label("Security & privacy", systemImage: "lock.shield") }
                    NavigationLink {
                        List {
                            Section("Prototype 0.1") { Text("Sample mail only"); Text("Mail stays in this sample mailbox. Optional sign-in and connection checks contact the provider directly."); Text("Demo Send only saves a local message.") }
                        }.navigationTitle("Help & about")
                    } label: { Label("Help & about", systemImage: "questionmark.circle") }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { store.save(); dismiss() } } }
            .onChange(of: store.snapshot.preferences.showSenderAddress) { _, _ in store.save() }
            .onChange(of: store.snapshot.preferences.mailboxLabel) { _, _ in store.save() }
            .onChange(of: store.snapshot.preferences.appearance) { _, _ in store.save() }
        }
    }
}

struct SecurityView: View {
    @EnvironmentObject private var lock: MailAppLock
    var body: some View {
        List {
            Section {
                Toggle("Lock Mail", isOn: Binding(get: { lock.enabled }, set: { enabled in
                    Task { await lock.authenticate(enabled ? .enable : .disable) }
                })).disabled(lock.busy)
                if !lock.message.isEmpty { Text(lock.message).font(.caption) }
            } footer: {
                Text("Use Face ID or your iPhone passcode when you return to Mail.")
            }
            Section("Implemented in this prototype") {
                Label("Plain text message rendering", systemImage: "checkmark.shield")
                Label("No external images or trackers loaded", systemImage: "checkmark.shield")
                Label("No JavaScript or message forms", systemImage: "checkmark.shield")
                Label("No read receipts or outgoing tracking", systemImage: "checkmark.shield")
                Label("Local data uses iOS complete file protection", systemImage: "checkmark.shield")
                Label("Mailbox cache excluded from backup", systemImage: "checkmark.shield")
            }
            Section("Connection checks") { NavigationLink("Check a custom mail server") { MailServerCheck() } }
            Section("Before real accounts") {
                Text("Live mail sync, provider-authorized sending aliases, and verified unsubscribe are pending.")
                Text("This prototype has not been audited or certified. An unlocked or compromised device can still expose local data.").foregroundStyle(.secondary)
            }
        }.navigationTitle("Security & privacy")
    }
}
