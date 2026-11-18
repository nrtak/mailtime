import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @Binding var folder: MailFolder
    @Binding var accountID: String?
    @Binding var group: String?
    @State private var newGroup = ""
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { accountID = nil; group = nil; folder = .inbox; dismiss() } label: { Label("All accounts", systemImage: "tray.full") }
                    ForEach(MailFolder.allCases) { item in
                        Button { folder = item; dismiss() } label: { Label(item == .sent ? "Demo Sent" : item.title, systemImage: item.symbol) }
                    }
                }
                Section("On this device") {
                    NavigationLink("Action queue") { ActionQueueView() }
                    NavigationLink("Offline mail packs") { OfflinePacksView() }
                    NavigationLink("Inspect link or QR code") { LinkInspector(initial: "") }
                }
                ForEach(store.snapshot.groups, id: \.self) { title in
                    Section {
                        Button("View this group") { group = title; accountID = nil; folder = .inbox; dismiss() }
                        ForEach(store.snapshot.accounts.filter { $0.group == title && (query.isEmpty || ($0.name + $0.address).localizedCaseInsensitiveContains(query)) }) { account in
                            HStack {
                                Button {
                                    accountID = account.id; group = nil; folder = .inbox; dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(account.name).font(.body.weight(.medium))
                                        Text(account.address).font(.caption).foregroundStyle(.secondary)
                                        if account.needsAttention { Label("Demo sync paused", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                    }.foregroundStyle(.primary)
                                }
                                Spacer()
                                NavigationLink { AccountEditor(account: account) } label: { Image(systemName: "slider.horizontal.3") }.frame(width: 40).accessibilityLabel("Edit \(account.name)")
                            }
                        }
                    } header: { Text(title) }
                }
                Section("New group") {
                    TextField("Group name", text: $newGroup)
                    Button("Add group") { store.addGroup(newGroup); newGroup = "" }.disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section { Text("These mailboxes use sample messages. The optional Outlook.com identity check is in Settings under Accounts & groups.").font(.caption).foregroundStyle(.secondary) }
            }
            .searchable(text: $query, prompt: "Find an account")
            .navigationTitle("Accounts")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct AccountEditor: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State var account: MailAccount
    @State private var editingReminder = false
    @State private var confirmRemoval = false
    private var live: MailAccount { store.account(account.id) ?? account }

    var body: some View {
        Form {
            Section("Account label") { TextField("Name", text: $account.name); Text(account.address).foregroundStyle(.secondary) }
            Section("Group") { Picker("Group", selection: $account.group) { ForEach(store.snapshot.groups, id: \.self) { Text($0).tag($0) } } }
            Section("Demo sync status") {
                SyncAccountRow(account: live)
                Button("Simulate expired sign-in") { store.simulateInterruption(account.id, issue: .signIn) }
                    .disabled(store.checking.contains(account.id))
                Button("Simulate network timeout") { store.simulateInterruption(account.id, issue: .timedOut) }
                    .disabled(store.checking.contains(account.id))
            }
            Section {
                Picker("Remind me after", selection: Binding(
                    get: { live.reminderMinutes ?? 0 }, set: { minutes in
                        editingReminder = true
                        Task {
                            await store.setOverdueReminder(account.id, minutes: minutes)
                            editingReminder = false
                        }
                    })) {
                    Text("Off").tag(0)
                    Text("1 minute (demo)").tag(1)
                    Text("2 hours").tag(120)
                    Text("6 hours").tag(360)
                    Text("24 hours").tag(1440)
                }.disabled(editingReminder)
                if let error = store.reminderErrors[account.id] {
                    Text(error).font(.caption)
                    if let minutes = live.reminderMinutes {
                        Button("Retry reminder") { Task { await store.setOverdueReminder(account.id, minutes: minutes) } }
                    }
                }
                if let error = store.storageError { Text(error).font(.caption) }
            } header: { Text("Overdue sync reminder") } footer: {
                Text("Measured from this mailbox’s last successful check. The lock-screen reminder omits addresses and message details.")
            }
            Section("Account capabilities · demo") {
                LabeledContent("Local folder moves", value: "Available")
                LabeledContent("Search", value: "On device")
                LabeledContent("Sample aliases", value: "\(account.aliases.count)")
                LabeledContent("Provider spam reporting", value: "Unconnected")
                LabeledContent("Background sync", value: "Unconnected")
            }
            Section("Sample sending identities") { Text(account.address); ForEach(account.aliases, id: \.self) { Text($0) }; Text("These are demo identities. Real aliases will require provider authorization.").font(.caption).foregroundStyle(.secondary) }
            Section {
                Button("Remove sample account from iPhone", role: .destructive) { confirmRemoval = true }
            }
        }.navigationTitle("Account preferences")
            .confirmationDialog("Remove this mailbox and its local copies?", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove " + account.address, role: .destructive) { if store.removeSampleAccount(account.id) { dismiss() } }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { store.updateAccount(account); dismiss() } } }
    }
}

struct SyncAccountRow: View {
    @EnvironmentObject private var store: MailStore
    let account: MailAccount
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.address).font(.subheadline.weight(.semibold))
            if let issue = account.issue { Label(issue.label, systemImage: "exclamationmark.triangle").font(.caption) }
            Text("Last successful check: \(account.lastSuccess?.formatted() ?? "Never")").font(.caption)
            if let retry = account.nextRetry {
                Text("Automatic retry: \(retry.formatted(date: .omitted, time: .standard))").font(.caption)
            }
            if store.checking.contains(account.id) {
                ProgressView("Checking sample mail…").font(.caption)
            } else {
                Button(account.issue == .signIn ? "Reconnect" : account.issue == nil ? "Check now" : "Retry") {
                    if account.issue == .signIn { confirm = true }
                    else { Task { await store.refreshSample(account.id) } }
                }.buttonStyle(.borderless)
            }
        }
        .confirmationDialog("Reconnect " + account.address + "?", isPresented: $confirm, titleVisibility: .visible) {
            ForEach(store.snapshot.accounts) { identity in
                Button(identity.address) { Task { await store.refreshSample(account.id, signedInSampleID: identity.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Choose the sample identity to reconnect. Only the matching mailbox can resume.") }
    }
}

struct CoverageView: View {
    @EnvironmentObject private var store: MailStore
    let ids: [String]
    var body: some View {
        List {
            Section {
                Text("Sample timestamps. A mailbox becomes stale one hour after its last successful check. Local search includes downloaded mail.")
            }
            ForEach(store.snapshot.accounts.filter { ids.contains($0.id) }) { account in
                VStack(alignment: .leading, spacing: 6) {
                    SyncAccountRow(account: account)
                    TimelineView(.periodic(from: .now, by: 60)) { tick in Text(account.sampleStatus(at: tick.date)) }
                    Text("Last attempt: \(account.lastAttempt?.formatted() ?? "Unknown")")
                }.font(.caption)
            }
        }.navigationTitle("Mailbox coverage")
    }
}

struct ActionQueueView: View {
    @EnvironmentObject private var store: MailStore
    var body: some View {
        List {
            ForEach(["Needs reply", "Waiting", "Done"], id: \.self) { status in
                Section(status) {
                    let items = store.snapshot.messages.filter { $0.action == status }
                    if items.isEmpty { Text("No messages").foregroundStyle(.secondary) }
                    ForEach(items) { mail in
                        NavigationLink { MessageView(messageID: mail.id) } label: {
                            VStack(alignment: .leading) {
                                Text(mail.subject)
                                Text(store.account(mail.accountID)?.address ?? "").font(.caption)
                                if let date = mail.reminder { Text(date.formatted()).font(.caption) }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Action queue")
    }
}

struct OfflinePacksView: View {
    @EnvironmentObject private var store: MailStore
    @State private var accountID = ""
    @State private var folder = MailFolder.inbox
    @State private var attachments = false
    @State private var limit = 16
    @State private var selected = Set<String>()
    @State private var result = ""
    private var candidates: [MailMessage] {
        store.snapshot.messages.filter { $0.folder == folder && (accountID.isEmpty || $0.accountID == accountID) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        Form {
            Section("Create a local copy") {
                Picker("Account", selection: $accountID) {
                    Text("All accounts").tag("")
                    ForEach(store.snapshot.accounts) { Text($0.address).tag($0.id) }
                }
                Picker("Folder", selection: $folder) { ForEach(MailFolder.allCases) { Text($0.title).tag($0) } }
                Toggle("Include sample attachments", isOn: $attachments).disabled(folder == .junk)
                Stepper("Pack limit: \(limit) KB", value: $limit, in: 1...256)
                ForEach(candidates) { mail in
                    Button {
                        if !selected.insert(mail.id).inserted { selected.remove(mail.id) }
                    } label: { Label(mail.subject, systemImage: selected.contains(mail.id) ? "checkmark.circle.fill" : "circle") }
                }
                Button("Save selected messages") { create() }.disabled(selected.isEmpty)
                if !result.isEmpty { Text(result).font(.caption) }
            }
            Section("Saved packs") {
                ForEach(store.snapshot.packs ?? []) { pack in
                    NavigationLink {
                        List((store.snapshot.packs ?? []).first { $0.id == pack.id }?.messages.filter { store.account($0.accountID) != nil } ?? []) { mail in
                            DisclosureGroup(mail.subject) {
                                Text(mail.senderAddress)
                                Text(verbatim: mail.body)
                                if let file = store.readableAttachment(for: mail) {
                                    Text(verbatim: file.name); Text(verbatim: file.text)
                                } else if mail.attachment != nil {
                                    Text("Attachment unavailable under the current mailbox restrictions.").font(.caption)
                                }
                            }
                        }.navigationTitle(pack.name)
                    } label: {
                        VStack(alignment: .leading) { Text(pack.name); Text("\(pack.payload.count) bytes · \(pack.date.formatted())").font(.caption) }
                    }
                }.onDelete { offsets in
                    store.snapshot.packs?.remove(atOffsets: offsets); store.save()
                }
            }
        }.navigationTitle("Offline mail packs")
            .onChange(of: accountID) { _, _ in selected.removeAll() }
            .onChange(of: folder) { _, _ in selected.removeAll() }
    }

    private func create() {
        let messages = candidates.filter { selected.contains($0.id) }.map { original in
            var mail = original
            if !attachments || folder == .junk { mail.attachment = nil }
            return mail
        }
        guard !messages.isEmpty, let data = try? JSONEncoder().encode(messages) else { return }
        guard data.count <= limit * 1024 else { result = "Selection exceeds the pack limit. Choose fewer messages or increase the limit."; return }
        let pack = OfflinePack(name: "\(store.account(accountID)?.name ?? "All accounts") · \(folder.title)", payload: data)
        store.snapshot.packs = (store.snapshot.packs ?? []) + [pack]
        store.save()
        result = store.storageError ?? "Saved \(messages.count) messages for offline reading."
        selected.removeAll()
    }
}
