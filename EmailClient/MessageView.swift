import SwiftUI
import UserNotifications

struct MessageView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    let messageID: String
    @State private var snoozeOpen = false
    @State private var composeOpen = false

    private func reply(_ mail: MailMessage, all: Bool) {
        composeOpen = store.prepareCompose(accountID: mail.accountID, group: nil, replyingTo: mail, all: all)
    }

    var body: some View {
        Group {
            if let mail = store.message(messageID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(mail.subject).font(.title2.bold()).textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mail.senderName).font(.headline)
                            Text(mail.senderAddress).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("Mailbox: \(store.account(mail.accountID)?.address ?? "Unknown")").font(.caption).foregroundStyle(.secondary)
                            Text(mail.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        let changes = store.senderChanges(for: mail)
                        if !changes.isEmpty {
                            VStack(alignment: .leading) {
                                Label("Sender details changed", systemImage: "person.crop.circle.badge.questionmark").font(.headline)
                                ForEach(changes, id: \.self) { Text($0).font(.subheadline) }
                            }
                        }
                        if mail.folder != .sent {
                            Button(store.isBlocked(mail) ? "Unblock sender on this iPhone" : "Block sender on this iPhone") {
                                store.toggleBlock(mail)
                            }.font(.caption)
                            Button(store.isFavorite(mail) ? "Remove favorite sender" : "Favorite this sender") {
                                store.toggleFavorite(mail)
                            }.font(.caption)
                        }
                        if let error = store.storageError { Text(error).foregroundStyle(.red) }
                        if mail.folder == .inbox {
                            let always = store.account(mail.accountID)?.prioritySenders?.contains(mail.senderAddress.lowercased()) == true
                            Menu("Inbox actions") {
                                Button(always ? "Stop always prioritizing this sender" : "Always prioritize this sender in this account") {
                                    store.togglePrioritySender(mail)
                                }
                                Button("Snooze…") { snoozeOpen = true }
                            }.sheet(isPresented: $snoozeOpen) { SnoozeEditor(mail: mail) }
                        }
                        MessageActions(mail: mail)
                        if let file = store.readableAttachment(for: mail) {
                            DisclosureGroup(file.name) { Text(verbatim: file.text) }
                        }
                        if let reason = mail.junkReason, mail.folder == .junk {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Why this is in Junk", systemImage: "exclamationmark.shield").font(.headline)
                                Text(reason).font(.subheadline)
                                Button("Restore to Inbox") { if store.move(mail.id, to: .inbox) { dismiss() } }.buttonStyle(.bordered)
                            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                        }
                        Label("Plain text · remote content never loaded", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        // A Text view never interprets message HTML or executes scripts.
                        Text(verbatim: mail.body.isEmpty ? "This message has no visible content." : mail.body)
                            .font(.body).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        let history = store.conversation(containing: mail)
                        ForEach(history.reversed().filter { $0.id != mail.id }) { item in
                            DisclosureGroup {
                                Text(verbatim: item.subject).font(.headline)
                                Text(verbatim: item.body)
                            } label: {
                                VStack(alignment: .leading) { Text(verbatim: item.senderAddress); Text(item.date.formatted()).font(.caption) }
                            }
                        }
                    }.padding(22)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { store.update(mail.id) { $0.unread.toggle() } } label: { Image(systemName: mail.unread ? "envelope.open" : "envelope.badge") }.accessibilityLabel(mail.unread ? "Mark read" : "Mark unread")
                        Spacer()
                        Button { store.update(mail.id) { $0.priority.toggle() } } label: { Image(systemName: mail.priority ? "star.fill" : "star") }.accessibilityLabel(mail.priority ? "Remove from Priority" : "Move to Priority")
                        Spacer()
                        Button { if store.move(mail.id, to: mail.folder == .junk ? .inbox : .junk) { dismiss() } } label: { Image(systemName: mail.folder == .junk ? "tray.and.arrow.up" : "exclamationmark.shield") }.accessibilityLabel(mail.folder == .junk ? "Restore to Inbox" : "Move to Junk")
                        Spacer()
                        Button { if store.move(mail.id, to: .archive) { dismiss() } } label: { Image(systemName: "archivebox") }.accessibilityLabel("Archive")
                        Spacer()
                        Menu("Reply", systemImage: "arrowshape.turn.up.left") {
                            Button("Reply") { reply(mail, all: false) }
                            if mail.replyAddresses(all: true) != mail.replyAddresses(all: false) {
                                Button("Reply All") { reply(mail, all: true) }
                            }
                        }
                    }
                }
            } else { ContentUnavailableView("Message unavailable", systemImage: "envelope") }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.update(messageID) { $0.unread = false } }
        .sheet(isPresented: $composeOpen) { ComposeView() }
    }
}

struct MessageActions: View {
    @EnvironmentObject private var store: MailStore
    let mail: MailMessage
    @State private var time = Date().addingTimeInterval(3600)
    @State private var feedback = ""
    @State private var scheduling = false
    private var legacyReminderID: String { "mail-action-" + mail.id }

    var body: some View {
        DisclosureGroup(mail.action ?? "Add follow-up") {
            Picker("Action", selection: Binding(get: { mail.action ?? "None" }, set: { status in
                let finished = status == "Done" || status == "None"
                if store.update(mail.id, { value in
                    value.action = status == "None" ? nil : status
                    value.watchForReply = nil
                    if finished { value.reminder = nil; value.reminderNotificationID = nil }
                }), finished { removeNotification() }
            })) {
                ForEach(["None", "Needs reply", "Waiting", "Done"], id: \.self) { Text($0).tag($0) }
            }.disabled(scheduling)
            if mail.outboundRecipients != nil {
                DatePicker("Follow up on", selection: $time, in: Date()...)
                Button("Remind me if nobody replies") { Task { await schedule(watchReply: true) } }.disabled(scheduling)
                if mail.watchForReply == true { Text(store.followUpStatus(mail, at: Date())).font(.caption) }
            }
            if ["Needs reply", "Waiting"].contains(mail.action ?? "") {
                if mail.outboundRecipients == nil { DatePicker("Remind me", selection: $time, in: Date()...) }
                Button("Set local reminder") { Task { await schedule() } }.disabled(scheduling)
                if let date = mail.reminder {
                    Text(date.formatted()).font(.caption)
                    Button("Remove reminder") { cancelReminder() }.disabled(scheduling)
                }
            }
            if !feedback.isEmpty { Text(feedback).font(.caption) }
        }
    }

    private func cancelReminder() {
        guard store.update(mail.id, { $0.reminder = nil; $0.reminderNotificationID = nil; $0.watchForReply = nil }) else { return }
        removeNotification()
    }

    private func removeNotification() {
        let center = UNUserNotificationCenter.current()
        let ids = [legacyReminderID] + (mail.reminderNotificationID.map { [$0] } ?? [])
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        feedback = ""
    }

    @MainActor private func schedule(watchReply: Bool = false) async {
        guard !scheduling else { return }
        scheduling = true
        defer { scheduling = false }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else {
                feedback = "Enable notifications in iPhone Settings to receive a reminder."; return
            }
            let target = time
            guard target > Date() else { feedback = "Choose a future time."; return }
            if watchReply && store.snapshot.messages.contains(where: { $0.isReply(to: mail) }) {
                feedback = "A reply is already in this mailbox."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Mail reminder"
            content.body = watchReply ? "Check for a reply in Mail." : "Review your follow-ups."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, target.timeIntervalSinceNow), repeats: false)
            let newID = legacyReminderID + "-" + UUID().uuidString
            try await center.add(UNNotificationRequest(identifier: newID, content: content, trigger: trigger))
            guard let current = store.message(mail.id), current.accountID == mail.accountID,
                  !watchReply || !store.snapshot.messages.contains(where: { $0.isReply(to: current) }),
                  (watchReply ? current.outboundRecipients != nil : ["Needs reply", "Waiting"].contains(current.action ?? "")),
                  store.update(mail.id, { value in
                      value.reminder = target
                      value.reminderNotificationID = newID
                      value.watchForReply = watchReply
                      if watchReply { value.action = "Waiting" }
                  }) else {
                center.removePendingNotificationRequests(withIdentifiers: [newID])
                center.removeDeliveredNotifications(withIdentifiers: [newID])
                return
            }
            let oldIDs = ([legacyReminderID] + (current.reminderNotificationID.map { [$0] } ?? [])).filter { $0 != newID }
            center.removePendingNotificationRequests(withIdentifiers: oldIDs)
            center.removeDeliveredNotifications(withIdentifiers: oldIDs)
            feedback = "Reminder scheduled."
        } catch { feedback = error.localizedDescription }
    }
}

struct SnoozeEditor: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    let mail: MailMessage
    @State private var date = Date().addingTimeInterval(3600)
    var body: some View {
        NavigationStack {
            Form {
                Button("Later today") {
                    let now = Date()
                    if let midnight = Calendar.current.dateInterval(of: .day, for: now)?.end,
                       store.snooze(mail, until: min(now.addingTimeInterval(3 * 3600), midnight.addingTimeInterval(-1))) { dismiss() }
                }
                Button("Tomorrow morning") {
                    let calendar = Calendar.current
                    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
                       let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow),
                       store.snooze(mail, until: morning) { dismiss() }
                }
                Button("Next Monday morning") {
                    let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)
                    if let next, store.snooze(mail, until: next) { dismiss() }
                }
                DatePicker("Choose a time", selection: $date, in: Date()...)
                Button("Snooze") { if store.snooze(mail, until: date) { dismiss() } }
                if (mail.snoozedUntil ?? .distantPast) > Date() {
                    Button("Return now") { if store.snooze(mail, until: nil) { dismiss() } }
                }
                if let error = store.storageError { Text(error) }
            }.navigationTitle("Snooze message")
        }.presentationDetents([.medium])
    }
}
