import CryptoKit
import Foundation

/// Content files are immutable. Replacing the small index commits all account changes together.
struct MailboxCache {
    let indexURL: URL
    private let fs = FileManager.default

    init(indexURL: URL) { self.indexURL = indexURL }

    private struct Index: Codable {
        var layout: Int
        var settings: MailSnapshot
        var files: [String: String]
        var draft: MailDraft?
    }
    private struct CheckedIndex: Codable {
        let payload: Data
        let digest: Data
    }

    private func decodeIndex(_ bytes: Data) throws -> Index {
        let decoder = JSONDecoder()
        if let checked = try? decoder.decode(CheckedIndex.self, from: bytes) {
            guard Data(SHA256.hash(data: checked.payload)) == checked.digest else {
                throw CocoaError(.coderReadCorrupt)
            }
            return try decoder.decode(Index.self, from: checked.payload)
        }
        // Builds through 15 wrote a plain index.
        return try decoder.decode(Index.self, from: bytes)
    }

    private func writeIndex(_ index: Index) throws {
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(index)
        let checked = CheckedIndex(payload: bytes, digest: Data(SHA256.hash(data: bytes)))
        try encoder.encode(checked).write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    private struct PackedMessage: Codable {
        let pack: UUID
        let order: Int
        let mail: MailMessage
    }
    private struct AccountFile: Codable {
        let owner: String
        var messages: [MailMessage]
        var copies: [PackedMessage]
        let draft: MailDraft?
    }
    private func filename(_ data: Data) -> String {
        "account-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private var directory: URL { indexURL.deletingLastPathComponent() }

    func load() throws -> MailSnapshot {
        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        if let legacy = try? decoder.decode(MailSnapshot.self, from: data) {
            guard legacy.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            try save(legacy)
            return legacy
        }
        let index = try decodeIndex(data)
        var result = index.settings
        guard [2, 3].contains(index.layout), result.version == 1, result.messages.isEmpty, result.draft.isEmpty, Set(result.accounts.map(\.id)).count == result.accounts.count, Set(index.files.keys) == Set(result.accounts.map(\.id)) else { throw CocoaError(.coderReadCorrupt) }
        var copies: [UUID: [PackedMessage]] = [:]
        for acct in result.accounts {
            guard let name = index.files[acct.id],
                  name.range(of: #"^account-[a-f0-9]{64}\.json$"#, options: .regularExpression) != nil else { throw CocoaError(.coderReadCorrupt) }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            guard filename(bytes) == name else { throw CocoaError(.coderReadCorrupt) }
            let part = try decoder.decode(AccountFile.self, from: bytes)
            guard part.owner == acct.id, part.messages.allSatisfy({ $0.accountID == acct.id }),
                  part.copies.allSatisfy({ $0.mail.accountID == acct.id }),
                  part.draft == nil || part.draft?.accountID == acct.id else { throw CocoaError(.coderReadCorrupt) }
            result.messages += part.messages
            if let draft = part.draft { result.draft = draft }
            for copy in part.copies { copies[copy.pack, default: []].append(copy) }
        }
        if let draft = index.draft {
            guard draft.isEmpty || draft.accountID.isEmpty && draft.from.isEmpty || index.files[draft.accountID] != nil else { throw CocoaError(.coderReadCorrupt) }
            result.draft = draft
        }
        result.packs = try result.packs?.map { head in
            var pack = head
            let rows = (copies[head.id] ?? []).sorted { $0.order < $1.order }
            pack.payload = try JSONEncoder().encode(rows.map(\.mail))
            return pack
        }
        guard Set(result.messages.map(\.id)).count == result.messages.count else { throw CocoaError(.coderReadCorrupt) }
        try? cleanUnreferenced(keeping: Set(index.files.values))
        return result
    }

    func save(_ value: MailSnapshot, expectsIndex: Bool = false) throws {
        if expectsIndex {
            let existing = try decodeIndex(Data(contentsOf: indexURL))
            guard [2, 3].contains(existing.layout) else { throw CocoaError(.coderReadCorrupt) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var metadata = value
        metadata.messages = []
        metadata.draft = MailDraft(accountID: "", from: "")
        var copies: [String: [PackedMessage]] = [:]
        metadata.packs = try value.packs?.map { pack in
            let rows = try JSONDecoder().decode([MailMessage].self, from: pack.payload)
            for (order, mail) in rows.enumerated() {
                copies[mail.accountID, default: []].append(PackedMessage(pack: pack.id, order: order, mail: mail))
            }
            var head = pack
            head.payload = Data()
            return head
        }
        let byAccount = Dictionary(grouping: value.messages, by: \.accountID)
        let ids = Set(value.accounts.map(\.id))
        guard ids.count == value.accounts.count, Set(value.messages.map(\.id)).count == value.messages.count,
              Set(byAccount.keys).isSubset(of: ids), Set(copies.keys).isSubset(of: ids),
              value.draft.isEmpty || value.draft.accountID.isEmpty && value.draft.from.isEmpty || ids.contains(value.draft.accountID) else { throw CocoaError(.coderInvalidValue) }
        var files: [String: String] = [:]
        for acct in value.accounts {
            let part = AccountFile(owner: acct.id, messages: byAccount[acct.id] ?? [],
                copies: copies[acct.id] ?? [], draft: nil)
            let bytes = try encoder.encode(part)
            let name = filename(bytes)
            let url = directory.appendingPathComponent(name)
            if fs.fileExists(atPath: url.path) {
                guard try Data(contentsOf: url) == bytes else { throw CocoaError(.coderReadCorrupt) }
            } else {
                try bytes.write(to: url, options: [.atomic, .completeFileProtection])
            }
            files[acct.id] = name
        }
        let index = Index(layout: 3, settings: metadata, files: files, draft: value.draft)
        try writeIndex(index)
        // Cleanup after commit may be retried on the next save or launch.
        try? cleanUnreferenced(keeping: Set(files.values))
    }

    func saveSyncAccounts(_ accounts: [MailAccount]) throws {
        var index = try decodeIndex(Data(contentsOf: indexURL))
        guard [2, 3].contains(index.layout), index.settings.accounts.map(\.id) == accounts.map(\.id) else {
            throw CocoaError(.coderReadCorrupt)
        }
        index.settings.accounts = accounts
        try writeIndex(index)
    }

    func saveDraft(_ draft: MailDraft) throws {
        var index = try decodeIndex(Data(contentsOf: indexURL))
        guard [2, 3].contains(index.layout), draft.isEmpty || draft.accountID.isEmpty && draft.from.isEmpty || index.files[draft.accountID] != nil else {
            throw CocoaError(.coderInvalidValue)
        }
        index.layout = 3
        index.draft = draft
        try writeIndex(index)
    }

    func clean() throws {
        let index = try decodeIndex(Data(contentsOf: indexURL))
        try cleanUnreferenced(keeping: Set(index.files.values))
    }

    private func cleanUnreferenced(keeping names: Set<String>) throws {
        for url in try fs.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("account-") && url.pathExtension == "json" && !names.contains(url.lastPathComponent) {
            try fs.removeItem(at: url)
        }
    }
}
