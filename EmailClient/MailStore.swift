import SwiftUI
import UserNotifications

@MainActor
final class MailStore: ObservableObject {
    @Published var snapshot: MailSnapshot
    @Published var notice: String?
    @Published var storageError: String?
    @Published private(set) var checking = Set<String>()
    @Published private(set) var reminderErrors: [String: String] = [:]
    private var reminderWrites: [String: Task<Void, Never>] = [:]
    @Published private(set) var loadFailed = false
    private var pendingDraftSave: Task<Void, Never>?
    private var savedDraft: MailDraft?
    private var undoMessage: MailMessage?
    var canUndo: Bool { undoMessage != nil }
    private let fileURL: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "DemoMailbox", directoryHint: .isDirectory)) {
        fileURL = directory.appending(path: "mailbox.json")
        snapshot = .sample()
        loadMailbox()
    }

    func loadMailbox() {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if names.contains(fileURL.lastPathComponent) || loadFailed {
                let saved = try MailboxCache(indexURL: fileURL).load()
                guard saved.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                snapshot = saved
                savedDraft = saved.draft
            }
            loadFailed = false
            storageError = nil
        } catch {
            loadFailed = true
            storageError = "Saved demo data could not be loaded. Changes will not overwrite it. \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save() -> Bool { persist(snapshot) }

    private func persist(_ value: MailSnapshot) -> Bool {
        guard !loadFailed else { return false }
        do {
            try MailboxCache(indexURL: fileURL).save(value)
            savedDraft = value.draft
            storageError = nil
            return true
        } catch {
            storageError = "Could not save changes on this iPhone. " + error.localizedDescription
            return false
        }
    }

    func scheduleDraftSave() {
        pendingDraftSave?.cancel()
        pendingDraftSave = Task {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            flushDraft()
        }
    }

    @discardableResult
    func flushDraft() -> Bool {
        pendingDraftSave?.cancel()
        pendingDraftSave = nil
        guard !loadFailed else { return false }
        if savedDraft == nil || storageError != nil { return save() }
        guard savedDraft != snapshot.draft else { return true }
        do {
            try MailboxCache(indexURL: fileURL).saveDraft(snapshot.draft)
            savedDraft = snapshot.draft
            return true
        } catch {
            storageError = "Could not save the draft on this iPhone. " + error.localizedDescription
            return false
        }
    }

    func discardDraft() -> Bool {
        let owner = account(snapshot.draft.accountID) ?? snapshot.accounts.first
        var next = snapshot
        next.draft = MailDraft(accountID: owner?.id ?? "", from: owner?.address ?? "")
        return commit(next)
    }

    private func commit(_ value: MailSnapshot) -> Bool {
        guard persist(value) else { return false }
        snapshot = value
        return true
    }

    func account(_ id: String) -> MailAccount? { snapshot.accounts.first { $0.id == id } }
    func message(_ id: String) -> MailMessage? { snapshot.messages.first { $0.id == id } }

    func messages(folder: MailFolder, accountID: String?, group: String?, priority: Bool, query: String) -> [MailMessage] {
        snapshot.messages.filter { mail in
            mail.folder == folder &&
            (accountID == nil || mail.accountID == accountID) &&
            (group == nil || account(mail.accountID)?.group == group) &&
            (!priority || folder != .inbox || mail.priority) &&
            (!snapshot.preferences.unreadOnly || mail.unread) &&
            (query.isEmpty || [mail.senderName, mail.senderAddress, mail.subject, mail.body, account(mail.accountID)?.address ?? ""].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.date > $1.date }
    }

    func readableAttachment(for copy: MailMessage) -> DemoAttachment? {
        guard copy.folder != .junk, account(copy.accountID) != nil,
              let current = message(copy.id), current.accountID == copy.accountID, current.folder != .junk,
              let attachment = current.attachment, attachment == copy.attachment else { return nil }
        return attachment
    }

    func isBlocked(_ mail: MailMessage) -> Bool {
        account(mail.accountID)?.blockedSenders?.contains(mail.senderAddress.lowercased()) == true
    }

    func toggleBlock(_ mail: MailMessage) {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == mail.accountID }) else { return }
        var next = snapshot
        var blocked = Set(next.accounts[index].blockedSenders ?? [])
        let sender = mail.senderAddress.lowercased()
        if blocked.insert(sender).inserted {
            for i in next.messages.indices where next.messages[i].accountID == mail.accountID &&
                next.messages[i].folder == .inbox && next.messages[i].senderAddress.lowercased() == sender {
                next.messages[i].folder = .junk
                next.messages[i].junkReason = "Blocked on this iPhone."
            }
        } else {
            blocked.remove(sender)
        }
        next.accounts[index].blockedSenders = blocked.sorted()
        if commit(next) { undoMessage = nil }
    }

    @discardableResult
    func update(_ id: String, _ change: (inout MailMessage) -> Void) -> Bool {
        guard let index = snapshot.messages.firstIndex(where: { $0.id == id }) else { return false }
        var next = snapshot
        change(&next.messages[index])
        return commit(next)
    }

    func move(_ id: String, to folder: MailFolder) {
        guard let mail = message(id) else { return }
        let saved = update(id) { value in
            value.folder = folder
            value.junkReason = folder == .junk ? "Moved to Junk by you. No spam report was sent." : nil
        }
        guard saved else { return }
        undoMessage = mail
        notice = folder == .inbox ? "Restored to Inbox" : "Moved to \(folder.title)"
    }

    func undoMove() {
        guard let old = undoMessage, let index = snapshot.messages.firstIndex(where: { $0.id == old.id }) else { return }
        var next = snapshot
        next.messages[index].folder = old.folder
        next.messages[index].junkReason = old.junkReason
        guard commit(next) else { return }
        undoMessage = nil
        notice = nil
    }

    func addGroup(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !snapshot.groups.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        snapshot.groups.append(clean)
        save()
    }

    func removeSampleAccount(_ id: String) -> Bool {
        guard account(id) != nil else { return true }
        var next = snapshot
        let reminders = next.messages.filter { $0.accountID == id }.map { "mail-action-" + $0.id } + ["mail-overdue-" + id]
        next.accounts.removeAll { $0.id == id }
        next.messages.removeAll { $0.accountID == id }
        next.favoriteSenders?[id] = nil
        next.views?.removeAll { $0.accountID == id }
        if next.draft.accountID == id || next.draft.originalAccount == id {
            next.draft = MailDraft(accountID: next.accounts.first?.id ?? "", from: next.accounts.first?.address ?? "")
        }
        do {
            next.packs = try next.packs?.compactMap { pack in
                let rows = try JSONDecoder().decode([MailMessage].self, from: pack.payload)
                let retained = rows.filter { $0.accountID != id }
                guard !retained.isEmpty else { return nil }
                var updated = pack
                updated.payload = try JSONEncoder().encode(retained)
                return updated
            }
        } catch { storageError = "Could not verify the offline copies."; return false }
        guard commit(next) else { return false }
        undoMessage = nil
        reminderErrors[id] = nil
        let pending = reminderWrites.removeValue(forKey: id)
        Task {
            await pending?.value
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: reminders)
            center.removeDeliveredNotifications(withIdentifiers: reminders)
        }
        do { try MailboxCache(indexURL: fileURL).clean() }
        catch { storageError = "Mailbox removed. Cached file cleanup will be retried on the next launch." }
        return true
    }

    func updateAccount(_ account: MailAccount) {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }), snapshot.groups.contains(account.group) else { return }
        snapshot.accounts[index].name = account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? account.address : account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.accounts[index].group = account.group
        save()
    }

    func sendDemo() -> Bool {
        let draft = snapshot.draft
        guard let account = account(draft.accountID), account.sendingAddresses.contains(draft.from), !draft.recipients.isEmpty, draft.recipients.allSatisfy(Self.validRecipient), !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var next = snapshot
        next.messages.insert(MailMessage(accountID: account.id, senderName: account.name, senderAddress: draft.from, subject: draft.subject.isEmpty ? "(No subject)" : draft.subject, body: "To: \(draft.recipient)\n\n\(draft.body)", unread: false, priority: false, folder: .sent, sentRecipients: draft.recipients, attachment: draft.attachment), at: 0)
        next.draft = MailDraft(accountID: account.id, from: account.address)
        guard commit(next) else { return false }
        undoMessage = nil
        notice = "Saved to Demo Sent. No email was transmitted."
        return true
    }

    static func validRecipient(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil
    }
}

extension MailStore {
    func isFavorite(_ mail: MailMessage) -> Bool {
        snapshot.favoriteSenders?[mail.accountID]?.contains(mail.senderAddress.lowercased()) == true
    }

    func toggleFavorite(_ mail: MailMessage) {
        var groups = snapshot.favoriteSenders ?? [:]
        var addresses = Set(groups[mail.accountID] ?? [])
        let address = mail.senderAddress.lowercased()
        if !addresses.insert(address).inserted { addresses.remove(address) }
        groups[mail.accountID] = addresses.sorted()
        snapshot.favoriteSenders = groups
        save()
    }

    func preSendChecks() -> [String] {
        let d = snapshot.draft
        guard let sender = account(d.accountID) else { return [] }
        var warnings: [String] = []
        if let original = d.originalAccount, original != sender.id {
            warnings.append("The conversation belongs to \(account(original)?.address ?? original). You selected \(d.from).")
        }
        if d.replyAll == true && d.recipients.count > 1 {
            warnings.append("Reply All includes \(d.recipients.count) recipients.")
        }
        let domain = d.from.split(separator: "@").last?.lowercased()
        let sentTo = Set(snapshot.messages.filter { $0.accountID == sender.id && $0.folder == .sent }.flatMap { mail -> [String] in
            (mail.outboundRecipients ?? []).map { $0.lowercased() }
        })
        let outside = d.recipients.filter { recipient in
            recipient.split(separator: "@").last?.lowercased() != domain &&
            !sentTo.contains(recipient.lowercased())
        }
        if !outside.isEmpty { warnings.append("First time sending from this account to: " + outside.joined(separator: ", ")) }
        if d.attachment == nil && (d.subject + " " + d.body).localizedCaseInsensitiveContains("attach") {
            warnings.append("You mention an attachment. No file is attached.")
        }
        return warnings
    }

    func senderChanges(for mail: MailMessage) -> [String] {
        guard mail.folder != .sent else { return [] }
        var evidence: [String] = []
        if let previous = snapshot.messages.filter({
            $0.accountID == mail.accountID && $0.date < mail.date && $0.folder != .junk && $0.folder != .sent &&
            $0.senderName.caseInsensitiveCompare(mail.senderName) == .orderedSame
        }).max(by: { $0.date < $1.date }), previous.senderAddress.caseInsensitiveCompare(mail.senderAddress) != .orderedSame {
            evidence.append("An earlier message in this mailbox used the same name with \(previous.senderAddress).")
        }
        if let reply = mail.replyTo, reply.caseInsensitiveCompare(mail.senderAddress) != .orderedSame {
            evidence.append("Replies go to \(reply).")
        }
        return evidence
    }
}

extension MailStore {
    func simulateInterruption(_ id: String, issue: SampleSyncIssue) {
        guard !checking.contains(id), let index = snapshot.accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = snapshot
        var account = next.accounts[index]
        account.syncIssue = issue
        account.needsAttention = true
        account.lastAttempt = Date()
        account.pendingDeliveryID = account.pendingDeliveryID ?? UUID().uuidString
        account.remainingTimeouts = issue == .timedOut ? 1 : nil
        account.nextRetry = issue == .timedOut ? Date().addingTimeInterval(5) : nil
        next.accounts[index] = account
        _ = commit(next)
    }

    func refreshSamples(_ ids: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = ids.makeIterator()
            for _ in 0..<min(4, ids.count) {
                if let id = remaining.next() { group.addTask { await self.refreshSample(id) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let id = remaining.next() else { break }
                group.addTask { await self.refreshSample(id) }
            }
        }
    }

    func refreshSample(_ id: String, signedInSampleID: String? = nil) async {
        guard !Task.isCancelled, let index = snapshot.accounts.firstIndex(where: { $0.id == id }),
              checking.insert(id).inserted else { return }
        defer { checking.remove(id) }
        var start = snapshot
        var account = start.accounts[index]
        account.lastAttempt = Date()
        if account.issue == .signIn && signedInSampleID != id {
            if signedInSampleID != nil { notice = "Different sample account selected. This mailbox is still paused." }
            start.accounts[index] = account
            _ = commit(start)
            return
        }
        if account.issue == .timedOut, let remaining = account.remainingTimeouts, remaining > 0 {
            account.remainingTimeouts = remaining - 1
            account.nextRetry = Date().addingTimeInterval(15)
            start.accounts[index] = account
            _ = commit(start)
            return
        }
        if account.issue != nil {
            account.syncIssue = .catchingUp
            account.pendingDeliveryID = account.pendingDeliveryID ?? UUID().uuidString
        }
        account.nextRetry = nil
        start.accounts[index] = account
        guard commit(start) else { return }

        // Represents waiting for the sample provider. An interrupted check leaves its checkpoint intact.
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let current = snapshot.accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = snapshot
        if let delivery = next.accounts[current].pendingDeliveryID {
            let messageID = "catch-up-" + id + "-" + delivery
            if !next.messages.contains(where: { $0.id == messageID }) {
                next.messages.insert(MailMessage(id: messageID, accountID: id, senderName: "Sample delivery",
                    senderAddress: "updates@example.com", subject: "Mail received while sync was paused",
                    body: "This sample message arrived during the interruption.",
                    folder: next.accounts[current].blockedSenders?.contains("updates@example.com") == true ? .junk : .inbox), at: 0)
            }
        }
        next.accounts[current].pendingDeliveryID = nil
        next.accounts[current].syncIssue = nil
        next.accounts[current].remainingTimeouts = nil
        next.accounts[current].needsAttention = false
        next.accounts[current].lastSuccess = Date()
        // The checkpoint, message and last-success time reach disk together.
        guard commit(next) else { return }
        if next.accounts[current].reminderMinutes != nil { scheduleOverdueReminder(id) }
    }

    var nextSampleRetry: Date? {
        snapshot.accounts.compactMap(\.nextRetry).min()
    }

    func retryDueSamples() async {
        let now = Date()
        let ids = snapshot.accounts.filter { ($0.nextRetry ?? .distantFuture) <= now }.map(\.id)
        // The view's deadline task may be cancelled when committing a new retry date.
        // Each due check owns its lifetime once started.
        for id in ids { Task { await self.refreshSample(id) } }
    }

    func setOverdueReminder(_ id: String, minutes: Int) async {
        guard [0, 1, 120, 360, 1440].contains(minutes) else { return }
        if minutes > 0 {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) else {
                    reminderErrors[id] = "Allow notifications in iPhone Settings to receive overdue reminders."
                    return
                }
            } catch { reminderErrors[id] = error.localizedDescription; return }
        }
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = snapshot
        next.accounts[index].reminderMinutes = minutes == 0 ? nil : minutes
        next.accounts[index].reminderEnabledAt = minutes == 0 ? nil : Date()
        guard commit(next) else { return }
        scheduleOverdueReminder(id)
    }

    private func scheduleOverdueReminder(_ id: String) {
        // Serialize replacements to prevent an older request overwriting a newer deadline.
        let previous = reminderWrites[id]
        reminderWrites[id] = Task { [weak self] in
            await previous?.value
            guard let self, let account = self.account(id) else { return }
            let center = UNUserNotificationCenter.current()
            let key = "mail-overdue-" + id
            center.removeDeliveredNotifications(withIdentifiers: [key])
            guard let minutes = account.reminderMinutes else {
                center.removePendingNotificationRequests(withIdentifiers: [key])
                self.reminderErrors[id] = nil
                return
            }
            let since = account.lastSuccess ?? account.reminderEnabledAt ?? Date()
            let delay = max(1, since.addingTimeInterval(Double(minutes) * 60).timeIntervalSinceNow)
            let content = UNMutableNotificationContent()
            content.title = "Mailbox reminder"
            content.body = "An inbox hasn’t been checked recently."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: trigger))
                self.reminderErrors[id] = nil
            } catch { self.reminderErrors[id] = "Could not schedule the reminder. " + error.localizedDescription }
        }
    }
}
