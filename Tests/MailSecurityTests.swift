import XCTest
import Combine
@testable import EmailClient

final class MailSecurityTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    @MainActor func testOldOfflineCopyLosesAttachmentAccessInJunk() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let copy = try XCTUnwrap(store.snapshot.messages.first { $0.attachment != nil })
        XCTAssertNotNil(store.readableAttachment(for: copy))
        store.move(copy.id, to: .junk)
        XCTAssertNil(store.readableAttachment(for: copy))
        store.move(copy.id, to: .inbox)
        var wrongAccount = copy
        wrongAccount.accountID = "unrelated"
        XCTAssertNil(store.readableAttachment(for: wrongAccount))
        XCTAssertNotNil(store.readableAttachment(for: copy))
    }

    @MainActor func testReconnectRequiresOriginalAccount() async throws {
        let store = MailStore(directory: try temporaryDirectory())
        let previous = try XCTUnwrap(store.account("cent"))
        await store.refreshSample("cent", signedInSampleID: "personal")
        XCTAssertEqual(store.account("cent")?.lastSuccess, previous.lastSuccess)
        XCTAssertEqual(store.account("cent")?.needsAttention, true)
        await store.refreshSample("cent", signedInSampleID: "cent")
        XCTAssertEqual(store.account("cent")?.needsAttention, false)
    }

    @MainActor func testSenderBlockIsScopedToOneMailbox() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let first = try XCTUnwrap(store.snapshot.messages.first { $0.accountID == "base" && $0.folder == .inbox })
        var other = first
        other.id = UUID().uuidString
        other.accountID = "personal"
        store.snapshot.messages.append(other)
        store.toggleBlock(first)
        XCTAssertTrue(store.isBlocked(first))
        XCTAssertFalse(store.isBlocked(other))
        XCTAssertEqual(store.message(first.id)?.folder, .junk)
        XCTAssertEqual(store.message(other.id)?.folder, .inbox)
    }

    @MainActor func testFromAddressMustBelongToSelectedAccount() throws {
        let store = MailStore(directory: try temporaryDirectory())
        store.snapshot.draft = MailDraft(accountID: "base", from: "hello@example.com", recipient: "a@example.com", body: "Reply")
        XCTAssertFalse(store.sendDemo(confirmed: store.snapshot.draft))
        XCTAssertEqual(store.snapshot.draft.body, "Reply")
        store.snapshot.draft.from = "hello@studio-mail.example"
        XCTAssertTrue(store.sendDemo(confirmed: store.snapshot.draft))
        XCTAssertTrue(store.snapshot.draft.isEmpty)
    }

    @MainActor func testFailedSendPreservesDraft() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        store.snapshot.draft = MailDraft(accountID: "base", from: "hello@studio-mail.example", recipient: "a@example.com", body: "Original draft")
        XCTAssertTrue(store.save())
        let index = directory.appendingPathComponent("mailbox.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let sent = store.snapshot.messages.filter { $0.folder == .sent }.count
        XCTAssertFalse(store.sendDemo(confirmed: store.snapshot.draft))
        XCTAssertFalse(store.discardDraft())
        XCTAssertEqual(store.snapshot.draft.body, "Original draft")
        XCTAssertEqual(store.snapshot.messages.filter { $0.folder == .sent }.count, sent)
    }

    @MainActor func testLegacyMigrationAndRemovalPreserveOtherAccount() throws {
        let directory = try temporaryDirectory()
        var legacy = MailSnapshot.sample()
        let first = try XCTUnwrap(legacy.messages.first { $0.accountID == "base" })
        let other = try XCTUnwrap(legacy.messages.first { $0.accountID == "personal" })
        legacy.packs = [OfflinePack(name: "Both", payload: try JSONEncoder().encode([other, first]))]
        legacy.draft = MailDraft(accountID: "base", from: "hello@studio-mail.example", body: "Private draft")
        let index = directory.appendingPathComponent("mailbox.json")
        try JSONEncoder().encode(legacy).write(to: index)
        let store = MailStore(directory: directory)
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.snapshot.packs?.first?.messages.map(\.id), [other.id, first.id])
        XCTAssertTrue(store.removeSampleAccount("base"))
        let restored = try MailboxCache(indexURL: index).load()
        XCTAssertNil(restored.accounts.first { $0.id == "base" })
        XCTAssertFalse(restored.messages.contains { $0.accountID == "base" })
        XCTAssertTrue(restored.draft.isEmpty)
        XCTAssertEqual(restored.packs?.first?.messages.map(\.id), [other.id])
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data("Private draft".utf8)))
            if url.lastPathComponent.hasPrefix("account-") {
                let contents = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertNotEqual(contents["owner"] as? String, "base")
            }
        }
    }

    @MainActor func testReplyToSentMailKeepsAliasAndOriginalRecipients() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let owner = try XCTUnwrap(store.account("base"))
        let alias = try XCTUnwrap(owner.aliases.first)
        var mail = MailMessage(accountID: owner.id, senderName: owner.name, senderAddress: alias,
                               subject: "Schedule", body: "To: a@example.com, b@example.com\n\nHello",
                               folder: .sent, copiedRecipients: ["B@example.com", "c@example.com"])
        XCTAssertEqual(mail.replyDraft(account: owner, all: false).recipient, "a@example.com")
        mail.sentRecipients = ["a@example.com", "b@example.com"]
        mail.folder = .archive
        let reply = mail.replyDraft(account: owner, all: true)
        XCTAssertEqual(reply.recipient, "a@example.com, b@example.com, c@example.com")
        XCTAssertEqual(reply.from, alias)
    }

    @MainActor func testMailboxRetryRestoresSavedDraft() throws {
        let directory = try temporaryDirectory()
        let index = directory.appendingPathComponent("mailbox.json")
        let initial = MailStore(directory: directory)
        initial.snapshot.draft.body = "Saved before restart"
        XCTAssertTrue(initial.save())
        let valid = try Data(contentsOf: index)
        try Data("incomplete".utf8).write(to: index)
        let store = MailStore(directory: directory)
        XCTAssertTrue(store.loadFailed)
        XCTAssertFalse(store.save())
        try valid.write(to: index)
        store.loadMailbox()
        XCTAssertFalse(store.loadFailed)
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.snapshot.draft.body, "Saved before restart")
    }

    @MainActor func testDraftFlushAndDiscardSurviveRelaunch() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let owner = try XCTUnwrap(store.account("base"))
        store.snapshot.draft = MailDraft(accountID: owner.id, from: owner.address, body: "First")
        XCTAssertTrue(store.save())
        let accountFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        store.snapshot.draft.body = "Second"
        store.scheduleDraftSave()
        XCTAssertTrue(store.flushDraft())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), accountFiles)
        XCTAssertEqual(MailStore(directory: directory).snapshot.draft.body, "Second")
        XCTAssertTrue(store.discardDraft())
        let restored = MailStore(directory: directory).snapshot.draft
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(restored.accountID, owner.id)
        XCTAssertEqual(restored.from, owner.address)
    }

    @MainActor func testBulkRefreshChecksEachRequestedAccount() async throws {
        let store = MailStore(directory: try temporaryDirectory())
        let baseline = Date(timeIntervalSince1970: 100)
        for i in store.snapshot.accounts.indices { store.snapshot.accounts[i].lastAttempt = baseline }
        let ids = Array(store.snapshot.accounts.map(\.id).dropLast())
        await store.refreshSamples(ids)
        XCTAssertTrue(store.checking.isEmpty)
        for account in store.snapshot.accounts {
            if ids.contains(account.id) { XCTAssertGreaterThan(try XCTUnwrap(account.lastAttempt), baseline) }
            else { XCTAssertEqual(account.lastAttempt, baseline) }
        }
    }

    @MainActor func testIndependentGroupAndInboxColorsSurviveRestart() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        var account = try XCTUnwrap(store.account("base"))
        store.setGroupColor(.green, for: account.group)
        account.labelColor = .purple
        XCTAssertTrue(store.updateAccount(account))
        let restored = MailStore(directory: directory)
        XCTAssertEqual(restored.snapshot.groupColors?[account.group], .green)
        XCTAssertEqual(restored.account(account.id)?.labelColor, .purple)
        restored.setGroupColor(nil, for: account.group)
        let cleared = MailStore(directory: directory)
        XCTAssertNil(cleared.snapshot.groupColors?[account.group])
        XCTAssertEqual(cleared.account(account.id)?.labelColor, .purple)
    }

    @MainActor func testMissingIndexPreservesAllAccountFiles() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        XCTAssertTrue(store.save())
        let index = directory.appendingPathComponent("mailbox.json")
        let previousIndex = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        let parts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let bytes = try parts.map { try Data(contentsOf: $0) }
        XCTAssertFalse(parts.isEmpty)
        XCTAssertFalse(store.save())
        let restarted = MailStore(directory: directory)
        XCTAssertTrue(restarted.loadFailed)
        XCTAssertFalse(restarted.flushDraft())
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        XCTAssertEqual(try parts.map { try Data(contentsOf: $0) }, bytes)
        try previousIndex.write(to: index)
        restarted.loadMailbox()
        XCTAssertFalse(restarted.loadFailed)
        XCTAssertEqual(Set(restarted.snapshot.messages.map(\.id)), Set(store.snapshot.messages.map(\.id)))
    }

    @MainActor func testGroupDraftRequiresExplicitSenderAndSurvivesRelaunch() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        store.prepareCompose(accountID: nil, group: "Office")
        XCTAssertEqual(store.snapshot.draft.accountID, "cent")
        store.prepareCompose(accountID: nil, group: "Studio")
        XCTAssertEqual(store.snapshot.draft.from, "")
        store.snapshot.draft.body = "Unfinished"
        store.snapshot.draft.recipient = "recipient@example.com"
        XCTAssertFalse(store.sendDemo(confirmed: store.snapshot.draft))
        XCTAssertTrue(store.flushDraft())
        let reopened = MailStore(directory: directory)
        reopened.prepareCompose(accountID: "personal", group: nil)
        XCTAssertTrue(reopened.snapshot.draft.isEmpty)
        XCTAssertEqual(reopened.snapshot.parkedDrafts, [store.snapshot.draft])
        XCTAssertTrue(reopened.resumeDraft(at: 0))
        XCTAssertEqual(reopened.snapshot.draft, store.snapshot.draft)
    }

    @MainActor func testTwoDraftsKeepTheirAliasAndAttachment() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let first = MailDraft(accountID: "base", from: "hello@studio-mail.example", subject: "First", body: "Text", attachment: DemoAttachment())
        store.snapshot.draft = first
        XCTAssertTrue(store.prepareCompose(accountID: "base", group: nil))
        XCTAssertTrue(store.snapshot.draft.isEmpty)
        store.snapshot.draft.subject = "Second"
        XCTAssertTrue(store.flushDraft())
        let restarted = MailStore(directory: directory)
        XCTAssertTrue(restarted.resumeDraft(at: 0))
        XCTAssertEqual(restarted.snapshot.draft, first)
        XCTAssertEqual(restarted.snapshot.parkedDrafts?.first?.subject, "Second")
    }

    @MainActor func testRemovingReplySourcePreservesOtherAccountDraftsAcrossRelaunch() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        var active = MailDraft(accountID: "base", from: "hello@studio-mail.example",
            recipient: "reader@example.com", subject: "Keep active", body: "Unsent text",
            originalAccount: "personal", replyParentID: "source-message", replyAll: true, attachment: DemoAttachment())
        var parked = active
        parked.subject = "Keep parked"
        let owned = MailDraft(accountID: "personal", from: "alex@example.com", body: "Removed with account")
        XCTAssertTrue(store.editMailbox {
            $0.draft = active
            $0.parkedDrafts = [owned, parked]
        })
        XCTAssertTrue(store.removeSampleAccount("personal"))
        active.originalAccount = nil
        active.replyParentID = nil
        parked.originalAccount = nil
        parked.replyParentID = nil
        let restarted = MailStore(directory: directory)
        XCTAssertEqual(restarted.snapshot.draft, active)
        XCTAssertEqual(restarted.snapshot.parkedDrafts, [parked])
        XCTAssertTrue(restarted.resumeDraft(at: 0))
        XCTAssertEqual(restarted.snapshot.draft, parked)
    }

    @MainActor func testComposeFromAllAccountsParksReplyAndStartsWithoutRecipients() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let parent = try XCTUnwrap(store.snapshot.messages.first { $0.accountID == "base" && $0.folder == .inbox })
        XCTAssertTrue(store.prepareCompose(accountID: parent.accountID, group: nil, replyingTo: parent))
        store.snapshot.draft.body = "Keep my reply"
        let reply = store.snapshot.draft
        XCTAssertTrue(store.prepareCompose(accountID: nil, group: nil))
        XCTAssertTrue(store.snapshot.draft.isEmpty)
        XCTAssertEqual(store.snapshot.draft.from, "")
        XCTAssertNil(store.snapshot.draft.replyParentID)
        XCTAssertFalse(store.sendDemo(confirmed: store.snapshot.draft))
        XCTAssertTrue(store.prepareCompose(accountID: parent.accountID, group: nil, replyingTo: parent))
        XCTAssertEqual(store.snapshot.draft, reply)
    }

    func testOutlookReconnectNeedsSuccessfulInboxCheckToClearWarning() throws {
        let previous = Date(timeIntervalSince1970: 1000)
        var record = MicrosoftIdentityRecord(subject: "account", address: "mail@example.com",
            issue: "Inbox refresh failed.", pinned: true, lastCheck: previous)
        record.signedIn(address: "mail@example.com", refreshToken: "test-renewal")
        let reloaded = try JSONDecoder().decode(MicrosoftIdentityRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(reloaded.issue, "Inbox refresh failed.")
        XCTAssertEqual(reloaded.lastCheck, previous)
        XCTAssertEqual(reloaded.pinned, true)
        let success = previous.addingTimeInterval(120)
        record.checkedInbox(at: success)
        XCTAssertNil(record.issue)
        XCTAssertEqual(record.lastCheck, success)
        record.signedIn(address: record.address, refreshToken: "replacement")
        XCTAssertNotNil(record.issue)
        XCTAssertEqual(record.lastCheck, success)
    }

    @MainActor func testConversationUsesReplyIDsWithinTheSameAccountAndJunkBoundary() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let root = try XCTUnwrap(store.snapshot.messages.first { $0.folder == .inbox })
        var reply = root
        reply.id = "local-reply"; reply.inReplyToID = root.id
        reply.date = root.date.addingTimeInterval(60)
        var other = reply
        other.id = "other-account"; other.accountID = "unrelated"
        var junk = reply
        junk.id = "junk-copy"; junk.folder = .junk
        store.snapshot.messages = [junk, other, reply, root]
        XCTAssertEqual(store.conversation(containing: root).map(\.id), [root.id, reply.id])
    }

    func testGraphPaginationOnlyAcceptsMicrosoftHTTPS() throws {
        XCTAssertTrue(OutlookCache.approvedPage(try XCTUnwrap(URL(string: "https://graph.microsoft.com/v1.0/me/messages?skip=1"))))
        for address in ["http://graph.microsoft.com/v1.0/me", "https://graph.microsoft.com.example.org/v1.0/me",
                        "https://other@graph.microsoft.com/v1.0/me", "https://graph.microsoft.com:4040/v1.0/me"] {
            XCTAssertFalse(OutlookCache.approvedPage(try XCTUnwrap(URL(string: address))))
        }
    }

    @MainActor func testSendRequiresUnchangedDraftAndDoesNotRepeat() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let original = MailDraft(recipient: "one@example.com", body: "Approved content")
        store.snapshot.draft = original
        store.snapshot.draft.recipient = "two@example.com"
        let before = store.snapshot.messages.count
        XCTAssertFalse(store.sendDemo(confirmed: original))
        XCTAssertEqual(store.snapshot.messages.count, before)
        let confirmed = store.snapshot.draft
        XCTAssertTrue(store.sendDemo(confirmed: confirmed))
        XCTAssertFalse(store.sendDemo(confirmed: confirmed))
        let restored = MailStore(directory: directory)
        XCTAssertEqual(restored.snapshot.messages.count, before + 1)
        XCTAssertTrue(restored.snapshot.draft.isEmpty)
        XCTAssertTrue(restored.snapshot.messages.contains { $0.sentRecipients == ["two@example.com"] })
    }

    @MainActor func testInterruptedSyncResumesOnceAfterRelaunch() async throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let previous = try XCTUnwrap(store.account("cent")?.lastSuccess)
        let refresh = Task { await store.refreshSample("cent", signedInSampleID: "cent") }
        await Task.yield()
        // Wait until the checkpoint is durable, before the simulated provider returns.
        for _ in 0..<100 where store.account("cent")?.issue != .catchingUp {
            try await Task.sleep(for: .milliseconds(1))
        }
        refresh.cancel()
        await refresh.value
        let restarted = MailStore(directory: directory)
        XCTAssertEqual(restarted.account("cent")?.issue, .catchingUp)
        XCTAssertEqual(restarted.account("cent")?.lastSuccess, previous)
        let delivery = try XCTUnwrap(restarted.account("cent")?.pendingDeliveryID)
        await restarted.retryDueSamples()
        await restarted.retryDueSamples()
        let restored = MailStore(directory: directory)
        XCTAssertEqual(restored.snapshot.messages.filter { $0.id == "catch-up-cent-" + delivery }.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(restored.account("cent")?.lastSuccess), previous)
        XCTAssertNil(restored.account("cent")?.issue)
    }

    @MainActor func testFailedDeletionAndMoveKeepOriginalState() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let message = try XCTUnwrap(store.snapshot.messages.first { $0.folder == .inbox })
        let pack = OfflinePack(name: "Saved", payload: try JSONEncoder().encode([message]))
        XCTAssertTrue(store.editMailbox { $0.packs = [pack] })
        let index = directory.appendingPathComponent("mailbox.json")
        let prior = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        XCTAssertFalse(store.editMailbox { $0.packs = [] })
        XCTAssertFalse(store.move(message.id, to: .archive))
        XCTAssertEqual(store.snapshot.packs?.first?.id, pack.id)
        XCTAssertEqual(store.message(message.id)?.folder, .inbox)
        try prior.write(to: index)
        let reopened = MailStore(directory: directory)
        XCTAssertEqual(reopened.snapshot.packs?.first?.id, pack.id)
        XCTAssertEqual(reopened.message(message.id)?.folder, .inbox)
    }

    @MainActor func testArchivedLegacySentReplyUsesOriginalRecipient() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let owner = try XCTUnwrap(store.account("base"))
        let mail = MailMessage(accountID: owner.id, senderName: owner.name, senderAddress: owner.address,
                               subject: "Legacy", body: "To: client@example.com\n\nHello", folder: .sent)
        XCTAssertTrue(store.editMailbox { $0.messages.append(mail) })
        XCTAssertTrue(store.move(mail.id, to: .archive))
        let restored = try XCTUnwrap(MailStore(directory: directory).message(mail.id))
        XCTAssertEqual(restored.replyDraft(account: owner, all: false).recipient, "client@example.com")
    }

    @MainActor func testDamagedDraftIndexIsPreservedUntilRecovery() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        store.snapshot.draft.body = "Original"
        XCTAssertTrue(store.save())
        let url = directory.appendingPathComponent("mailbox.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        let changed = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: "Original", with: "Modified")
        XCTAssertNotEqual(Data(changed.utf8), payload)
        envelope["payload"] = Data(changed.utf8).base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: envelope)
        try damaged.write(to: url)
        let reopened = MailStore(directory: directory)
        XCTAssertTrue(reopened.loadFailed)
        XCTAssertFalse(store.save())
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    @MainActor func testPreviousIndexLayoutCanLoadAndSave() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        store.snapshot.draft.body = "Keep this draft"
        XCTAssertTrue(store.save())
        let url = directory.appendingPathComponent("mailbox.json")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let plainIndex = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payload"] as? String)))
        try plainIndex.write(to: url)
        let reopened = MailStore(directory: directory)
        XCTAssertEqual(reopened.snapshot.draft.body, "Keep this draft")
        XCTAssertTrue(reopened.save())
        XCTAssertEqual(MailStore(directory: directory).snapshot.draft.body, "Keep this draft")
    }

    @MainActor func testFiftyInboxesShareRefreshSlotsWithOverlappingRequests() async throws {
        let store = MailStore(directory: try temporaryDirectory())
        let ids = (0..<50).map { "test-\($0)" }
        let baseline = Date(timeIntervalSince1970: 100)
        store.snapshot.accounts = ids.map {
            MailAccount(id: $0, name: $0, address: $0 + "@example.com", group: "Test",
                        aliases: [], lastSuccess: baseline, lastAttempt: baseline)
        }
        store.snapshot.messages = []
        var previous = Set<String>()
        var starts: [String: Int] = [:]
        var peak = 0
        let observation = store.$checking.sink { active in
            peak = max(peak, active.count)
            for id in active.subtracting(previous) { starts[id, default: 0] += 1 }
            previous = active
        }
        let first = Task { await store.refreshSamples(Array(ids.prefix(30))) }
        let second = Task { await store.refreshSamples(Array(ids.suffix(30))) }
        await first.value
        await second.value
        observation.cancel()
        XCTAssertEqual(peak, 4)
        XCTAssertEqual(starts, Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }))
        XCTAssertTrue(store.snapshot.accounts.allSatisfy { ($0.lastSuccess ?? .distantPast) > baseline })
    }

    @MainActor func testReopeningReadMessageLeavesIndexUntouched() throws {
        let directory = try temporaryDirectory()
        let store = MailStore(directory: directory)
        let id = try XCTUnwrap(store.snapshot.messages.first?.id)
        XCTAssertTrue(store.update(id) { $0.unread = false })
        XCTAssertTrue(store.save())
        let url = directory.appendingPathComponent("mailbox.json")
        func inode() throws -> NSNumber {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
        }
        let before = try inode()
        XCTAssertTrue(store.update(id) { $0.unread = false })
        XCTAssertEqual(try inode(), before)
    }

    func testSyncWarningUsesExactOneHourBoundary() {
        let checked = Date(timeIntervalSince1970: 1000)
        var account = MailAccount(id: "office", name: "Office", address: "office@example.com",
                                  group: "Work", aliases: [], lastSuccess: checked)
        let deadline = checked.addingTimeInterval(3600)
        XCTAssertEqual(account.staleAt, deadline)
        XCTAssertEqual(account.sampleStatus(at: deadline.addingTimeInterval(-1)), "Current")
        XCTAssertEqual(account.sampleStatus(at: deadline), "Not checked recently")
        account.syncIssue = .signIn
        XCTAssertNil(account.staleAt)
        XCTAssertEqual(account.sampleStatus(at: checked), SampleSyncIssue.signIn.label)
    }

    @MainActor func testPriorityRuleIsPerAccountAndSearchMatchesAttachmentName() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let original = MailMessage(accountID: "base", senderName: "Billing", senderAddress: "billing@example.com",
            subject: "Documents", body: "Please review", priority: false, attachment: DemoAttachment(name: "invoice.pdf"))
        var other = original
        other.id = UUID().uuidString
        other.accountID = "personal"
        XCTAssertTrue(store.editMailbox { $0.messages = [original, other] })
        store.togglePrioritySender(original)
        XCTAssertEqual(store.messages(folder: .inbox, accountID: nil, group: nil, priority: true, query: "invoice.pdf").map(\.id), [original.id])
        store.togglePrioritySender(original)
        XCTAssertTrue(store.messages(folder: .inbox, accountID: nil, group: nil, priority: true, query: "").isEmpty)
    }

    @MainActor func testSnoozeUndoPreservesMessageContent() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let mail = try XCTUnwrap(store.snapshot.messages.first { $0.folder == .inbox })
        let date = Date().addingTimeInterval(600)
        XCTAssertTrue(store.snooze(mail, until: date))
        XCTAssertEqual(store.message(mail.id)?.snoozedUntil, date)
        store.undoMove()
        XCTAssertEqual(store.message(mail.id), mail)
    }

    @MainActor func testOnlyMatchingReplyResolvesWatch() throws {
        let store = MailStore(directory: try temporaryDirectory())
        let sent = MailMessage(accountID: "base", senderName: "Office", senderAddress: "contact@studio-mail.example",
            subject: "Delivery", body: "When?", folder: .sent, sentRecipients: ["partner@example.com"],
            action: "Waiting", reminder: Date(), watchForReply: true)
        XCTAssertTrue(store.editMailbox { $0.messages.append(sent) })
        var reply = MailMessage(accountID: "personal", senderName: "Partner", senderAddress: "partner@example.com",
            subject: "Re: Delivery", body: "Tomorrow", inReplyToID: sent.id)
        XCTAssertTrue(store.commitDeliveries([reply], to: store.snapshot))
        XCTAssertEqual(store.message(sent.id)?.watchForReply, true)
        reply.accountID = "base"
        reply.id = UUID().uuidString
        XCTAssertTrue(store.commitDeliveries([reply], to: store.snapshot))
        XCTAssertNil(store.message(sent.id)?.reminder)
        XCTAssertEqual(store.message(sent.id)?.action, "Done")
    }
}
