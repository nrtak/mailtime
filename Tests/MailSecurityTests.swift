import XCTest
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
        XCTAssertFalse(store.sendDemo())
        XCTAssertEqual(store.snapshot.draft.body, "Reply")
        store.snapshot.draft.from = "hello@studio-mail.example"
        XCTAssertTrue(store.sendDemo())
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
        XCTAssertFalse(store.sendDemo())
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
        let ids = store.snapshot.accounts.map(\.id)
        await store.refreshSamples(ids)
        XCTAssertTrue(store.checking.isEmpty)
        XCTAssertTrue(store.snapshot.accounts.allSatisfy { $0.lastAttempt != nil })
    }
}
