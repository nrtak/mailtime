import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var store: MailStore
    @EnvironmentObject private var outlook: OutlookSignIn
    @State private var folder: MailFolder = .inbox
    @State private var accountID: String?
    @State private var group: String?
    @State private var priority = true
    @State private var query = ""
    @State private var statusTime = Date()
    @Environment(\.scenePhase) private var scenePhase
    @State private var accountsOpen = false
    @State private var settingsOpen = false
    @State private var composeOpen = false

    @State private var filtersOpen = false
    @State private var senderFilter = ""
    @State private var afterDate: Date?
    @State private var snoozedOnly = false
    @State private var moveTarget: MailMessage?
    @State private var snoozeTarget: MailMessage?
    @State private var attachmentsOnly = false
    @State private var favoritesOnly = false
    @State private var namingView = false
    @State private var viewName = ""

    private var scope: String { accountID.flatMap { store.account($0)?.name } ?? group ?? "All accounts" }
    private var visible: [MailMessage] {
        store.messages(folder: folder, accountID: accountID, group: group,
                       priority: priority && query.isEmpty && senderFilter.isEmpty && afterDate == nil && !snoozedOnly, query: query, at: statusTime).filter { mail in
            let sleeping = folder == .inbox && (mail.snoozedUntil ?? .distantPast) > statusTime
            return (folder != .inbox || (snoozedOnly ? sleeping : !sleeping || !query.isEmpty)) &&
                (!attachmentsOnly || mail.attachment != nil) && (!favoritesOnly || store.isFavorite(mail)) &&
                (afterDate == nil || mail.date >= (afterDate ?? .distantPast)) &&
                (senderFilter.isEmpty || mail.senderName.localizedCaseInsensitiveContains(senderFilter) ||
                 mail.senderAddress.localizedCaseInsensitiveContains(senderFilter))
        }
    }
    private var scoped: [MailAccount] {
        store.snapshot.accounts.filter { (accountID == nil || $0.id == accountID) && (group == nil || $0.group == group) }
    }
    private var filtering: Bool {
        !query.isEmpty || !senderFilter.isEmpty || afterDate != nil || snoozedOnly || attachmentsOnly || favoritesOnly || store.snapshot.preferences.unreadOnly
    }

    @ViewBuilder private func swipeButton(_ action: MailSwipe, mail: MailMessage) -> some View {
        switch action {
        case .read:
            Button(mail.unread ? "Read" : "Unread", systemImage: "envelope") { store.toggleRead(mail) }
        case .archive where mail.folder != .archive && mail.folder != .junk:
            Button("Archive", systemImage: "archivebox") { store.move(mail.id, to: .archive) }
        case .snooze where mail.folder == .inbox:
            Button("Snooze", systemImage: "clock") { snoozeTarget = mail }
        default:
            Button("Move", systemImage: "folder") { moveTarget = mail }
        }
    }

    var body: some View {
        let messages = visible
        let accounts = scoped
        let attention = accounts.filter { $0.issue != nil }
        let wakeDates = folder == .inbox ? store.snapshot.messages.compactMap(\.snoozedUntil) : []
        let outlookDeadlines = outlook.saved.compactMap { $0.lastCheck?.addingTimeInterval(3600) }
        let deadline = (accounts.compactMap(\.staleAt) + wakeDates + outlookDeadlines).filter { $0 > statusTime }.min()
        return NavigationStack {
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
                    if let issue = outlook.saved.first(where: { $0.issue != nil }) {
                        NavigationLink { OutlookIdentityView() } label: {
                            Label("Outlook sync needs attention · " + issue.address, systemImage: "exclamationmark.triangle")
                        }
                    }
                    else if let staleOutlook = outlook.saved.first(where: { $0.lastCheck.map { statusTime.timeIntervalSince($0) >= 3600 } == true }) {
                        NavigationLink { OutlookReader(item: staleOutlook) } label: {
                            Label("Outlook hasn’t been checked recently · " + staleOutlook.address, systemImage: "clock")
                        }
                    }
                    let stale = accounts.filter { $0.issue == nil && $0.sampleStatus(at: statusTime) != "Current" }
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
                    if filtering {
                        Button { filtersOpen = true } label: {
                            Label("Search filters · " + scope + " · " + folder.title, systemImage: "line.3.horizontal.decrease")
                        }
                    }
                    if folder == .inbox && query.isEmpty && senderFilter.isEmpty && afterDate == nil && !snoozedOnly {
                        Picker("Inbox", selection: $priority) {
                            Text("Priority").tag(true)
                            Text("All").tag(false)
                        }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    if messages.isEmpty {
                        ContentUnavailableView(filtering ? "No matching local messages" : "No downloaded messages in this view",
                            systemImage: filtering ? "magnifyingglass" : "tray",
                            description: Text(!attention.isEmpty ? "Some mailboxes still need attention." : filtering ? "Change or clear your filters." : "Pull to check the selected sample mailboxes."))
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
                    ForEach(messages) { mail in
                        NavigationLink(value: mail.id) { MailRow(mail: mail) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                swipeButton(store.snapshot.preferences.trailingSwipe ?? .archive, mail: mail)
                            }
                            .swipeActions(edge: .leading) {
                                swipeButton(store.snapshot.preferences.leadingSwipe ?? .read, mail: mail)
                            }
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: store.snapshot.accounts.map(\.id), initial: true) { _, ids in
                if let selected = accountID, !ids.contains(selected) {
                    accountID = nil
                    group = nil
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { statusTime = Date() }
            }
            .task(id: scenePhase == .active ? deadline : nil) {
                guard scenePhase == .active, let deadline else { return }
                let delay = max(0, deadline.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(1)) } catch { return }
                statusTime = Date()
            }
            .refreshable {
                let ids = scoped.map(\.id)
                await store.refreshSamples(ids)
            }
            .navigationTitle(folder == .inbox ? "Inbox" : folder == .sent ? "Demo Sent" : folder.title)
            .navigationDestination(for: String.self) { id in
                MessageView(messageID: id)
            }
            .searchable(text: $query, prompt: "Search local mail")
            .searchSuggestions {
                Button("Filter by sender or account") { filtersOpen = true }
                Button("With attachments") { attachmentsOnly = true }
            }
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
                        Button("Search filters") { filtersOpen = true }
                        Toggle("Unread only", isOn: store.preference(\.unreadOnly))
                        Toggle("Attachments only", isOn: $attachmentsOnly)
                        Toggle("Favorite senders only", isOn: $favoritesOnly)
                        Button("Save this view") { viewName = ""; namingView = true }
                        ForEach(store.snapshot.views ?? []) { saved in
                            Button(saved.name) {
                                guard store.editMailbox({ $0.preferences.unreadOnly = saved.unread }) else { return }
                                folder = saved.folder; accountID = saved.accountID; group = saved.group
                                priority = saved.priority; query = saved.query; attachmentsOnly = saved.attachments
                                senderFilter = saved.senderFilter ?? ""; afterDate = saved.afterDate; snoozedOnly = saved.snoozedOnly ?? false
                                favoritesOnly = saved.favoritesOnly ?? false
                            }
                        }
                        if let views = store.snapshot.views, !views.isEmpty {
                            Menu("Remove saved view") {
                                ForEach(views) { saved in
                                    Button(saved.name, role: .destructive) {
                                        store.editMailbox { $0.views?.removeAll { $0.id == saved.id } }
                                    }
                                }
                            }
                        }
                        Button("Clear filters") { guard store.editMailbox({ $0.preferences.unreadOnly = false }) else { return }; favoritesOnly = false; attachmentsOnly = false; senderFilter = ""; afterDate = nil; snoozedOnly = false; query = "" }
                    } label: { Image(systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }.accessibilityLabel("Filter messages")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        composeOpen = store.prepareCompose(accountID: accountID, group: group)
                    } label: { Image(systemName: "square.and.pencil") }
                    .contextMenu {
                        if !store.snapshot.draft.isEmpty { Button("Resume current draft") { composeOpen = true } }
                        ForEach(Array((store.snapshot.parkedDrafts ?? []).enumerated()), id: \.offset) { i, draft in
                            Button((draft.subject.isEmpty ? "Draft" : draft.subject) + " · " + draft.from) {
                                composeOpen = store.resumeDraft(at: i)
                            }
                        }
                    }.accessibilityLabel("Compose")
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
            .sheet(item: $snoozeTarget) { mail in SnoozeEditor(mail: mail) }
            .sheet(item: $moveTarget) { mail in
                NavigationStack {
                    List(MailFolder.allCases.filter { $0 != .sent && $0 != mail.folder }) { destination in
                        Button(destination.title) { if store.move(mail.id, to: destination) { moveTarget = nil } }
                    }.navigationTitle("Move message")
                    .safeAreaInset(edge: .bottom) { if let error = store.storageError { Text(error) } }
                }.presentationDetents([.medium])
            }
            .sheet(isPresented: $filtersOpen) {
                NavigationStack {
                    Form {
                        TextField("From name or email address", text: $senderFilter).textInputAutocapitalization(.never)
                        Picker("Search in", selection: Binding(get: {
                            accountID.map { "account-" + $0 } ?? group.map { "group-" + $0 } ?? ""
                        }, set: { selection in
                            accountID = selection.hasPrefix("account-") ? String(selection.dropFirst(8)) : nil
                            group = selection.hasPrefix("group-") ? String(selection.dropFirst(6)) : nil
                        })) {
                            Text("All accounts").tag("")
                            ForEach(store.snapshot.groups, id: \.self) { Text($0).tag("group-" + $0) }
                            ForEach(store.snapshot.accounts) { Text($0.address).tag("account-" + $0.id) }
                        }
                        Toggle("Has attachment", isOn: $attachmentsOnly)
                        Toggle("Limit by date", isOn: Binding(get: { afterDate != nil }, set: { afterDate = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                        if let date = afterDate {
                            DatePicker("On or after", selection: Binding(get: { date }, set: { afterDate = Calendar.current.startOfDay(for: $0) }), displayedComponents: .date)
                        }
                        if folder == .inbox { Toggle("Snoozed only", isOn: $snoozedOnly) }
                    }.navigationTitle("Search filters")
                    .toolbar { Button("Done") { filtersOpen = false } }
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
                    views.append(SavedView(name: name, folder: folder, accountID: accountID, group: group, priority: priority, unread: store.snapshot.preferences.unreadOnly, attachments: attachmentsOnly, snoozedOnly: snoozedOnly, senderFilter: senderFilter, afterDate: afterDate, favoritesOnly: favoritesOnly, query: query))
                    store.editMailbox { $0.views = views }
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
                        .font(.caption2.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background((account.labelColor?.color ?? .blue).opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .leading) {
                            if let tint = account.labelColor { Capsule().fill(tint.color).frame(width: 3).accessibilityHidden(true) }
                        }
                }
            }
        }.padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: spokenLabel))
    }
}
