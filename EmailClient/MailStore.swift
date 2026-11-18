import SwiftUI
import UserNotifications

@MainActor
final class MailStore: ObservableObject {
    @Published var snapshot: MailSnapshot
    @Published var notice: String?
    @Published var storageError: String?
    @Published private(set) var checking = Set<String>()
    @Published private var scheduledChecks = Set<String>()
    private static let refreshBatchSize = 4
    private var refreshWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    @Published private(set) var reminderErrors: [String: String] = [:]
    private var reminderWrites: [String: Task<Void, Never>] = [:]
    @Published private(set) var loadFailed = false
    private var pendingDraftSave: Task<Void, Never>?
    private var savedDraft: MailDraft?
    private enum UndoField { case folder, unread, snooze }
    private var undoField: UndoField = .folder
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
            if !names.contains(fileURL.lastPathComponent),
               names.contains(where: { $0.hasPrefix("account-") && $0.hasSuffix(".json") }) {
                throw CocoaError(.fileReadCorruptFile)
            }
            if names.contains(fileURL.lastPathComponent) {
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

    private func persist(_ value: MailSnapshot, syncMetadataOnly: Bool = false) -> Bool {
        guard !loadFailed else { return false }
        do {
            let cache = MailboxCache(indexURL: fileURL)
            if syncMetadataOnly, savedDraft != nil, storageError == nil {
                try cache.saveSyncAccounts(value.accounts)
            } else {
                try cache.save(value, expectsIndex: savedDraft != nil)
                savedDraft = value.draft
            }
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

    @discardableResult
    func prepareCompose(accountID: String?, group: String?, replyingTo mail: MailMessage? = nil, all: Bool = false) -> Bool {
        var next = snapshot
        var parked = next.parkedDrafts ?? []
        if let mail {
            guard mail.accountID == accountID, let owner = account(mail.accountID) else { return false }
            func matchesReply(_ draft: MailDraft) -> Bool {
                draft.accountID == mail.accountID && draft.replyParentID == mail.id && draft.replyAll == all
            }
            if matchesReply(next.draft) && !next.draft.isEmpty { return true }
            if let index = parked.firstIndex(where: matchesReply) {
                next.draft = parked.remove(at: index)
            } else {
                next.draft = mail.replyDraft(account: owner, all: all)
            }
        } else {
            let choices = next.accounts.filter {
                (accountID == nil || $0.id == accountID) && (group == nil || $0.group == group)
            }
            let owner = choices.count == 1 ? choices.first : nil
            next.draft = MailDraft(accountID: owner?.id ?? "", from: owner?.address ?? "", composeGroup: group)
        }
        if !snapshot.draft.isEmpty { parked.append(snapshot.draft) }
        next.parkedDrafts = parked
        return commit(next)
    }

    func resumeDraft(at index: Int) -> Bool {
        var next = snapshot
        guard var parked = next.parkedDrafts, parked.indices.contains(index) else { return false }
        next.draft = parked.remove(at: index)
        if !snapshot.draft.isEmpty { parked.append(snapshot.draft) }
        next.parkedDrafts = parked
        return commit(next)
    }

    @discardableResult
    func editMailbox(_ edit: (inout MailSnapshot) -> Void) -> Bool {
        var next = snapshot
        edit(&next)
        return commit(next)
    }

    func preference<Value>(_ key: WritableKeyPath<MailPreferences, Value>) -> Binding<Value> {
        Binding(get: { self.snapshot.preferences[keyPath: key] }, set: { value in
            self.editMailbox { $0.preferences[keyPath: key] = value }
        })
    }

    func discardDraft() -> Bool {
        let owner = account(snapshot.draft.accountID) ?? snapshot.accounts.first
        var next = snapshot
        next.draft = MailDraft(accountID: owner?.id ?? "", from: owner?.address ?? "")
        return commit(next)
    }

    private func commit(_ value: MailSnapshot, syncMetadataOnly: Bool = false) -> Bool {
        guard persist(value, syncMetadataOnly: syncMetadataOnly) else { return false }
        snapshot = value
        return true
    }

    func conversation(containing mail: MailMessage) -> [MailMessage] {
        let members = snapshot.messages.filter { $0.accountID == mail.accountID && ($0.folder == .junk) == (mail.folder == .junk) }
        let children = Dictionary(grouping: members, by: { $0.inReplyToID ?? $0.id })
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var pending = [mail.id]
        var visited = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            if let parent = byID[id]?.inReplyToID { pending.append(parent) }
            pending.append(contentsOf: (children[id] ?? []).map(\.id))
        }
        return members.filter { visited.contains($0.id) }.sorted { $0.date < $1.date }
    }

    func account(_ id: String) -> MailAccount? { snapshot.accounts.first { $0.id == id } }
    func message(_ id: String) -> MailMessage? { snapshot.messages.first { $0.id == id } }

    func messages(folder: MailFolder, accountID: String?, group: String?, priority: Bool, query: String, at now: Date = Date()) -> [MailMessage] {
        let groupIDs = group.map { selected in
            Set(snapshot.accounts.lazy.filter { $0.group == selected }.map(\.id))
        }
        let matchingMailboxes = query.isEmpty ? Set<String>() :
            Set(snapshot.accounts.lazy.filter { $0.address.localizedCaseInsensitiveContains(query) }.map(\.id))
        let rules = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, Set($0.prioritySenders ?? [])) })
        return snapshot.messages.filter { mail in
            mail.folder == folder &&
            (accountID == nil || mail.accountID == accountID) &&
            (groupIDs?.contains(mail.accountID) ?? true) &&
            (!priority || folder != .inbox || mail.priority || rules[mail.accountID]?.contains(mail.senderAddress.lowercased()) == true) &&
            (!snapshot.preferences.unreadOnly || mail.unread) &&
            (query.isEmpty || matchingMailboxes.contains(mail.accountID) ||
             mail.senderName.localizedCaseInsensitiveContains(query) || mail.senderAddress.localizedCaseInsensitiveContains(query) ||
             (mail.folder != .junk && mail.attachment?.name.localizedCaseInsensitiveContains(query) == true) ||
             mail.subject.localizedCaseInsensitiveContains(query) || mail.body.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            func displayDate(_ mail: MailMessage) -> Date {
                guard folder == .inbox, let until = mail.snoozedUntil, until <= now else { return mail.date }
                return max(mail.date, until)
            }
            return displayDate(lhs) > displayDate(rhs)
        }
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
        var message = snapshot.messages[index]
        change(&message)
        guard message != snapshot.messages[index] else { return true }
        var next = snapshot
        next.messages[index] = message
        return commit(next)
    }

    @discardableResult
    func move(_ id: String, to folder: MailFolder) -> Bool {
        guard let mail = message(id) else { return false }
        let saved = update(id) { value in
            if value.folder == .sent, value.sentRecipients == nil { value.sentRecipients = value.outboundRecipients }
            value.folder = folder
            value.junkReason = folder == .junk ? "Moved to Junk by you. No spam report was sent." : nil
        }
        guard saved else { return false }
        undoMessage = mail
        undoField = .folder
        notice = folder == .inbox ? "Restored to Inbox" : "Moved to \(folder.title)"
        return true
    }

    func toggleRead(_ mail: MailMessage) {
        guard update(mail.id, { $0.unread.toggle() }) else { return }
        undoMessage = mail
        undoField = .unread
        notice = mail.unread ? "Marked read" : "Marked unread"
    }

    @discardableResult
    func snooze(_ mail: MailMessage, until date: Date?) -> Bool {
        guard date.map({ $0 > Date() }) ?? true, message(mail.id)?.folder == .inbox, update(mail.id, { $0.snoozedUntil = date }) else { return false }
        undoMessage = mail
        undoField = .snooze
        notice = date.map { "Snoozed until " + $0.formatted() } ?? "Snooze ended"
        return true
    }

    func followUpStatus(_ mail: MailMessage, at now: Date) -> String {
        guard let due = mail.reminder, due <= now else { return "Watching for a reply" }
        guard let account = account(mail.accountID), account.sampleStatus(at: now) == "Current",
              let checked = account.lastSuccess, checked >= due else { return "Check for a reply · refresh this inbox" }
        return "No reply in downloaded mail"
    }

    @discardableResult
    func commitDeliveries(_ incoming: [MailMessage], to state: MailSnapshot) -> Bool {
        var next = state
        var known = Set(next.messages.map(\.id))
        var cancellations: [String] = []
        for mail in incoming where known.insert(mail.id).inserted {
            guard next.accounts.contains(where: { $0.id == mail.accountID }) else { return false }
            next.messages.insert(mail, at: 0)
            guard mail.outboundRecipients == nil, let parent = mail.inReplyToID,
                  let i = next.messages.firstIndex(where: { $0.accountID == mail.accountID && $0.id == parent && $0.watchForReply == true && mail.isReply(to: $0) }) else { continue }
            cancellations.append(next.messages[i].reminderNotificationID ?? "mail-action-" + parent)
            next.messages[i].watchForReply = nil
            next.messages[i].action = "Done"
            next.messages[i].reminder = nil
            next.messages[i].reminderNotificationID = nil
        }
        guard commit(next) else { return false }
        if !cancellations.isEmpty {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: cancellations)
            center.removeDeliveredNotifications(withIdentifiers: cancellations)
        }
        return true
    }

    func togglePrioritySender(_ mail: MailMessage) {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == mail.accountID }) else { return }
        let address = mail.senderAddress.lowercased()
        editMailbox { next in
            var senders = Set(next.accounts[index].prioritySenders ?? [])
            if !senders.insert(address).inserted { senders.remove(address) }
            next.accounts[index].prioritySenders = senders.sorted()
        }
    }

    func undoMove() {
        guard let old = undoMessage, let index = snapshot.messages.firstIndex(where: { $0.id == old.id }) else { return }
        var next = snapshot
        switch undoField {
        case .folder:
            next.messages[index].folder = old.folder
            next.messages[index].junkReason = old.junkReason
        case .unread: next.messages[index].unread = old.unread
        case .snooze: next.messages[index].snoozedUntil = old.snoozedUntil
        }
        guard commit(next) else { return }
        undoMessage = nil
        notice = nil
    }

    func addGroup(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !snapshot.groups.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        editMailbox { $0.groups.append(clean) }
    }

    func removeSampleAccount(_ id: String) -> Bool {
        guard account(id) != nil else { return true }
        var next = snapshot
        let reminders = next.messages.filter { $0.accountID == id }.flatMap { mail -> [String] in
            let base = "mail-action-" + mail.id
            return [base] + (mail.reminderNotificationID.map { [$0] } ?? [])
        } + ["mail-overdue-" + id]
        next.parkedDrafts = next.parkedDrafts?.filter { $0.accountID != id }.map { $0.detachingReply(from: id) }
        next.accounts.removeAll { $0.id == id }
        next.messages.removeAll { $0.accountID == id }
        next.favoriteSenders?[id] = nil
        next.views?.removeAll { $0.accountID == id }
        if next.draft.accountID == id {
            next.draft = MailDraft(accountID: next.accounts.first?.id ?? "", from: next.accounts.first?.address ?? "")
        } else {
            next.draft = next.draft.detachingReply(from: id)
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

    func setGroupColor(_ color: MailLabelColor?, for group: String) {
        guard snapshot.groups.contains(group) else { return }
        var next = snapshot
        var colors = next.groupColors ?? [:]
        colors[group] = color
        next.groupColors = colors
        _ = commit(next)
    }

    @discardableResult
    func updateAccount(_ account: MailAccount) -> Bool {
        guard let index = snapshot.accounts.firstIndex(where: { $0.id == account.id }),
              snapshot.groups.contains(account.group) else { return false }
        var next = snapshot
        let name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.accounts[index].name = name.isEmpty ? account.address : name
        next.accounts[index].group = account.group
        next.accounts[index].labelColor = account.labelColor
        next.accounts[index].pinned = account.pinned
        next.accounts[index].signatures = account.signatures
        return commit(next)
    }

    func sendDemo(confirmed draft: MailDraft) -> Bool {
        guard snapshot.draft == draft else {
            notice = "The draft changed. Review it again before sending."
            return false
        }
        guard let account = account(draft.accountID), draft.composeGroup == nil || draft.composeGroup == account.group, account.sendingAddresses.contains(draft.from), !draft.recipients.isEmpty, draft.recipients.allSatisfy(Self.validRecipient), !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var next = snapshot
        next.messages.insert(MailMessage(accountID: account.id, senderName: account.name, senderAddress: draft.from, subject: draft.subject.isEmpty ? "(No subject)" : draft.subject, body: "To: \(draft.recipient)\n\n\(draft.body)" + (draft.signature.map { "\n\n" + $0 } ?? ""), unread: false, priority: false, folder: .sent, sentRecipients: draft.recipients, attachment: draft.attachment, inReplyToID: draft.replyParentID), at: 0)
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
        editMailbox { $0.favoriteSenders = groups }
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

    private func waitForRefreshChange(while blocked: () -> Bool) async {
        guard blocked(), !Task.isCancelled else { return }
        let id = UUID()
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        refreshWaiters[id] = continuation
        defer {
            refreshWaiters.removeValue(forKey: id)
            continuation.finish()
        }
        var iterator = events.makeAsyncIterator()
        while blocked() && !Task.isCancelled {
            guard await iterator.next() != nil else { return }
        }
    }

    private func wakeRefreshWaiters() {
        for waiter in refreshWaiters.values { waiter.yield(()) }
    }

    func refreshSample(_ id: String, signedInSampleID: String? = nil) async {
        await refreshSamples([id], signedInSampleID: signedInSampleID)
    }

    func refreshSamples(_ ids: [String], signedInSampleID: String? = nil) async {
        // A reconnect carries an explicit identity choice. Let an older ordinary check
        // finish first so that coalescing cannot discard that choice.
        if let id = signedInSampleID, ids.contains(id) {
            await waitForRefreshChange { self.scheduledChecks.contains(id) }
        }
        let existing = Set(snapshot.accounts.map(\.id))
        var claimed = Set<String>()
        let ordered = ids.filter { existing.contains($0) && !scheduledChecks.contains($0) && claimed.insert($0).inserted }
        guard !Task.isCancelled, !ordered.isEmpty else { return }
        scheduledChecks.formUnion(claimed)
        defer { scheduledChecks.subtract(claimed); wakeRefreshWaiters() }

        var remaining = ordered[...]
        while !remaining.isEmpty && !Task.isCancelled {
            // All entry points share these slots on the main actor.
            await waitForRefreshChange { self.checking.count >= Self.refreshBatchSize }
            guard !Task.isCancelled else { return }
            let slots = Self.refreshBatchSize - checking.count
            guard slots > 0 else { continue }
            let batch = remaining.prefix(slots)
            remaining = remaining.dropFirst(batch.count)
            await refreshBatch(Set(batch), signedInSampleID: signedInSampleID)
            if storageError != nil || remaining.isEmpty { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
    }

    private func refreshBatch(_ requested: Set<String>, signedInSampleID: String?) async {
        var start = snapshot
        var ready: [String] = []
        var attempted = Set<String>()
        for i in start.accounts.indices where requested.contains(start.accounts[i].id) {
            var account = start.accounts[i]
            attempted.insert(account.id)
            account.lastAttempt = Date()
            if account.issue == .signIn && signedInSampleID != account.id {
                if signedInSampleID != nil { notice = "Different sample account selected. This mailbox is still paused." }
            } else if account.issue == .timedOut, let remaining = account.remainingTimeouts, remaining > 0 {
                account.remainingTimeouts = remaining - 1
                account.nextRetry = Date().addingTimeInterval(15)
            } else {
                if account.issue != nil {
                    account.syncIssue = .catchingUp
                    account.pendingDeliveryID = account.pendingDeliveryID ?? UUID().uuidString
                    account.nextRetry = Date()
                }
                ready.append(account.id)
            }
            start.accounts[i] = account
        }
        guard !attempted.isEmpty else { return }
        checking.formUnion(attempted)
        defer { checking.subtract(attempted); wakeRefreshWaiters() }
        guard commit(start, syncMetadataOnly: true), !ready.isEmpty else { return }

        // A sample provider batch has one simulated network wait.
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard !Task.isCancelled else { return }
        let completed = Set(ready)
        var next = snapshot
        var deliveries: [MailMessage] = []
        for i in next.accounts.indices where completed.contains(next.accounts[i].id) {
            var account = next.accounts[i]
            if let delivery = account.pendingDeliveryID {
                let key = "catch-up-" + account.id + "-" + delivery
                deliveries.append(MailMessage(id: key, accountID: account.id, senderName: "Sample delivery",
                        senderAddress: "updates@example.com", subject: "Mail received while sync was paused",
                        body: "This sample message arrived during the interruption.",
                        folder: account.blockedSenders?.contains("updates@example.com") == true ? .junk : .inbox))
            }
            account.pendingDeliveryID = nil
            account.syncIssue = nil
            account.nextRetry = nil
            account.remainingTimeouts = nil
            account.needsAttention = false
            account.lastSuccess = Date()
            next.accounts[i] = account
        }
        let saved = deliveries.isEmpty ? commit(next, syncMetadataOnly: true) : commitDeliveries(deliveries, to: next)
        guard saved else { return }
        for account in next.accounts where completed.contains(account.id) && account.reminderMinutes != nil {
            scheduleOverdueReminder(account.id)
        }
    }

    private func retryDate(_ account: MailAccount) -> Date? {
        guard !scheduledChecks.contains(account.id) else { return nil }
        return account.nextRetry ?? (account.issue == .catchingUp ? Date.distantPast : nil)
    }

    var nextSampleRetry: Date? {
        guard storageError == nil else { return nil }
        return snapshot.accounts.compactMap(retryDate).min()
    }

    func retryDueSamples() async {
        let now = Date()
        let ids = snapshot.accounts.filter { (retryDate($0) ?? .distantFuture) <= now }.map(\.id)
        // Updating the deadline replaces the view task. The batch owns its completion.
        await Task { await refreshSamples(ids) }.value
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
