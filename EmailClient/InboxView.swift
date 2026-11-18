import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var store: MailStore
    @State private var folder: MailFolder = .inbox
    @State private var accountID: String?
    @State private var group: String?
    @State private var priority = true
    @State private var query = ""
    @State private var statusTime = Date()
    @State private var accountsOpen = false
    @State private var settingsOpen = false
    @State private var composeOpen = false

    @State private var attachmentsOnly = false
    @State private var favoritesOnly = false
    @State private var namingView = false
    @State private var viewName = ""

    private var scope: String { accountID.flatMap { store.account($0)?.name } ?? group ?? "All accounts" }
    private var visible: [MailMessage] { store.messages(folder: folder, accountID: accountID, group: group, priority: priority, query: query).filter { (!attachmentsOnly || $0.attachment != nil) && (!favoritesOnly || store.isFavorite($0)) } }
    private var scoped: [MailAccount] {
        store.snapshot.accounts.filter { (accountID == nil || $0.id == accountID) && (group == nil || $0.group == group) }
    }
    private var attention: [MailAccount] { scoped.filter { $0.issue != nil } }
    private var filtering: Bool {
        !query.isEmpty || attachmentsOnly || favoritesOnly || store.snapshot.preferences.unreadOnly
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "testtube.2")
                        Text("Demo mailbox · sample messages only")
                    }.font(.caption).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if let error = store.storageError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    }
                    let stale = scoped.filter { $0.issue == nil && $0.sampleStatus(at: statusTime) != "Current" }
                    if !attention.isEmpty || !stale.isEmpty {
                        NavigationLink {
                            SyncStatusView(ids: (attention + stale).map(\.id))
                        } label: {
                            Label(attention.isEmpty ? "Mail hasn’t been checked recently" :
                                  attention.count == 1 ? "Sync needs attention" : "Sync needs attention in \(attention.count) accounts",
                                  systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                        }
                    }
                    if folder == .inbox {
                        Picker("Inbox", selection: $priority) {
                            Text("Priority").tag(true)
                            Text("All").tag(false)
                        }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if visible.isEmpty {
                        ContentUnavailableView(filtering ? "No matching local messages" : "No downloaded messages in this view",
                            systemImage: filtering ? "magnifyingglass" : "tray",
                            description: Text(!attention.isEmpty ? "Some mailboxes still need attention." : filtering ? "Change or clear your filters." : "Pull to check the selected sample mailboxes."))
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(visible) { mail in
                        NavigationLink(value: mail.id) { MailRow(mail: mail) }
                            .swipeActions(edge: .trailing) {
                                if folder == .junk {
                                    Button("Restore", systemImage: "tray.and.arrow.up") { store.move(mail.id, to: .inbox) }.tint(.green)
                                } else {
                                    Button("Junk", systemImage: "exclamationmark.shield") { store.move(mail.id, to: .junk) }.tint(.orange)
                                    Button("Archive", systemImage: "archivebox") { store.move(mail.id, to: .archive) }.tint(.blue)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button(mail.unread ? "Read" : "Unread", systemImage: mail.unread ? "envelope.open" : "envelope.badge") { store.update(mail.id) { $0.unread.toggle() } }.tint(.indigo)
                            }
                    }
                }
            }
            .listStyle(.plain)
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { statusTime = $0 }
            .refreshable {
                let ids = scoped.map(\.id)
                await store.refreshSamples(ids)
            }
            .navigationTitle(folder == .inbox ? "Inbox" : folder == .sent ? "Demo Sent" : folder.title)
            .navigationDestination(for: String.self) { MessageView(messageID: $0) }
            .searchable(text: $query, prompt: "Search local mail")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { accountsOpen = true } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Accounts and mailboxes")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { accountsOpen = true } label: { Label(scope, systemImage: "tray.full").lineLimit(1) }
                }
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Toggle("Unread only", isOn: $store.snapshot.preferences.unreadOnly).onChange(of: store.snapshot.preferences.unreadOnly) { _, _ in store.save() }
                        Toggle("Attachments only", isOn: $attachmentsOnly)
                        Toggle("Favorite senders only", isOn: $favoritesOnly)
                        Button("Save this view") { viewName = ""; namingView = true }
                        ForEach(store.snapshot.views ?? []) { saved in
                            Button(saved.name) {
                                folder = saved.folder; accountID = saved.accountID; group = saved.group
                                priority = saved.priority; query = saved.query; attachmentsOnly = saved.attachments
                                favoritesOnly = saved.favoritesOnly ?? false
                                store.snapshot.preferences.unreadOnly = saved.unread; store.save()
                            }
                        }
                        if let views = store.snapshot.views, !views.isEmpty {
                            Menu("Remove saved view") {
                                ForEach(views) { saved in
                                    Button(saved.name, role: .destructive) {
                                        store.snapshot.views?.removeAll { $0.id == saved.id }
                                        store.save()
                                    }
                                }
                            }
                        }
                        Button("Clear filters") { favoritesOnly = false; attachmentsOnly = false; query = ""; store.snapshot.preferences.unreadOnly = false; store.save() }
                    } label: { Image(systemName: (favoritesOnly || attachmentsOnly || store.snapshot.preferences.unreadOnly) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }.accessibilityLabel("Filter messages")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if store.snapshot.draft.isEmpty, let accountID, let account = store.account(accountID) {
                            store.snapshot.draft = MailDraft(accountID: account.id, from: account.address)
                        }
                        composeOpen = true
                    } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("Compose")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = store.notice {
                    HStack {
                        Text(notice).font(.caption)
                        Spacer()
                        if store.canUndo { Button("Undo") { store.undoMove() }.font(.caption.weight(.semibold)) }
                        Button { store.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss notice")
                    }.padding().mailGlass().padding(.horizontal).padding(.bottom, 4)
                }
            }
            .sheet(isPresented: $accountsOpen) {
                AccountsView(folder: $folder, accountID: $accountID, group: $group)
            }
            .alert("Save current view", isPresented: $namingView) {
                TextField("View name", text: $viewName)
                Button("Save") {
                    let name = viewName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    var views = store.snapshot.views ?? []
                    views.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    views.append(SavedView(name: name, folder: folder, accountID: accountID, group: group, priority: priority, unread: store.snapshot.preferences.unreadOnly, attachments: attachmentsOnly, favoritesOnly: favoritesOnly, query: query))
                    store.snapshot.views = views; store.save()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $settingsOpen) { SettingsView() }
            .sheet(isPresented: $composeOpen) { ComposeView() }
        }
    }
}

struct MailRow: View {
    @EnvironmentObject private var store: MailStore
    let mail: MailMessage
    private var spokenLabel: String {
        var fields = [mail.unread ? "Unread" : "Read", mail.senderName]
        if store.snapshot.preferences.showSenderAddress { fields.append(mail.senderAddress) }
        fields.append(mail.subject)
        if let account = store.account(mail.accountID) {
            switch store.snapshot.preferences.mailboxLabel {
            case "Name": fields.append(account.name)
            case "Address": fields.append(account.address)
            default: break
            }
        }
        return fields.joined(separator: ". ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(mail.unread ? Color.blue : Color.clear).frame(width: 7, height: 7).padding(.top, 7).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mail.senderName).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(mail.date, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                if store.snapshot.preferences.showSenderAddress { Text(verbatim: mail.senderAddress).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text(mail.subject).font(.subheadline.weight(mail.unread ? .semibold : .regular)).lineLimit(1)
                Text(mail.body.isEmpty ? "No visible message content" : mail.body.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if store.snapshot.preferences.mailboxLabel != "Hidden", let account = store.account(mail.accountID) {
                    Text(store.snapshot.preferences.mailboxLabel == "Name" ? account.name : account.address)
                        .font(.caption2.weight(.medium)).foregroundStyle(.blue)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: spokenLabel))
    }
}
