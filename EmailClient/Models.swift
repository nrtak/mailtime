import Foundation

struct MailAccount: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    var group: String
    var aliases: [String]
    var lastSuccess: Date?
    var lastAttempt: Date?
    var needsAttention: Bool = false
    var syncIssue: SampleSyncIssue?
    var pendingDeliveryID: String?
    var remainingTimeouts: Int?
    var nextRetry: Date?
    var reminderMinutes: Int?
    var reminderEnabledAt: Date?

    var blockedSenders: [String]?
    var sendingAddresses: [String] { [address] + aliases }
    var issue: SampleSyncIssue? { syncIssue ?? (needsAttention ? .signIn : nil) }
}

enum SampleSyncIssue: String, Codable {
    case signIn, timedOut, catchingUp

    var label: String {
        switch self {
        case .signIn: return "Sign-in required"
        case .timedOut: return "Connection timed out"
        case .catchingUp: return "Catch-up incomplete"
        }
    }
}

enum MailFolder: String, Codable, CaseIterable, Identifiable {
    case inbox, junk, archive, sent
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .junk: return "exclamationmark.shield"
        case .archive: return "archivebox"
        case .sent: return "paperplane"
        }
    }
}

struct MailMessage: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var accountID: String
    var senderName: String
    var senderAddress: String
    var subject: String
    var body: String
    var date: Date = Date()
    var unread: Bool = true
    var priority: Bool = true
    var folder: MailFolder = .inbox
    var receivedAs: String?
    var replyTo: String?
    var sentRecipients: [String]?
    var copiedRecipients: [String]?
    var attachment: DemoAttachment?
    var action: String?
    var reminder: Date?
    var junkReason: String? = nil
}

extension MailMessage {
    var outboundRecipients: [String]? {
        if let sentRecipients { return sentRecipients }
        guard folder == .sent else { return nil }
        let header = body.prefix { !$0.isNewline }
        guard header.hasPrefix("To: ") else { return [] }
        return header.dropFirst(4).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func replyAddresses(all: Bool) -> [String] {
        let direct = outboundRecipients ?? [replyTo ?? senderAddress]
        let addresses = all ? direct + (copiedRecipients ?? []) : Array(direct.prefix(1))
        var seen = Set<String>()
        return addresses.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func replyDraft(account: MailAccount, all: Bool) -> MailDraft {
        let identity = outboundRecipients == nil ? receivedAs : senderAddress
        let from = account.sendingAddresses.first { $0.lowercased() == identity?.lowercased() }
            ?? (identity == nil && account.aliases.isEmpty ? account.address : "")
        return MailDraft(accountID: account.id, from: from, recipient: replyAddresses(all: all).joined(separator: ", "),
                         subject: subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject,
                         originalAccount: account.id, replyAll: all)
    }
}

struct MailDraft: Codable, Equatable {
    var accountID: String = "personal"
    var from: String = "alex@example.com"
    var recipient: String = ""
    var subject: String = ""
    var body: String = ""
    var originalAccount: String?
    var replyAll: Bool?
    var attachment: DemoAttachment?
    var isEmpty: Bool { recipient.isEmpty && subject.isEmpty && body.isEmpty && attachment == nil }
}

struct MailPreferences: Codable {
    var showSenderAddress = true
    var mailboxLabel = "Address"
    var appearance = "System"
    var unreadOnly = false
}

struct MailSnapshot: Codable {
    var version = 1
    var accounts: [MailAccount]
    var groups: [String]
    var messages: [MailMessage]
    var favoriteSenders: [String: [String]]?
    var views: [SavedView]?
    var packs: [OfflinePack]?
    var preferences = MailPreferences()
    var draft = MailDraft()
}

extension MailSnapshot {
    static func sample() -> MailSnapshot {
        var accounts = [
            MailAccount(id: "personal", name: "Personal", address: "alex@example.com", group: "Personal", aliases: ["hello@example.com"]),
            MailAccount(id: "base", name: "Studio · Contact", address: "contact@studio-mail.example", group: "Studio", aliases: ["hello@studio-mail.example"]),
            MailAccount(id: "orders", name: "Studio · Orders", address: "orders@studio-mail.example", group: "Studio", aliases: []),
            MailAccount(id: "cent", name: "Office · General", address: "office@office-mail.example", group: "Office", aliases: [], needsAttention: true)
        ]
        let rows: [(String, String, String, String, String, Bool, Bool, MailFolder, String?)] = [
            ("base", "Jordan Lee", "jordan@partner.example", "Updated delivery schedule", "Hi Alex,\n\nThe revised dates are ready for review. We can deliver the first shipment on Thursday, followed by the remaining items early next week.\n\nDoes that work for your team?\n\nBest,\nJordan", true, true, .inbox, nil),
            ("orders", "Maya Chen", "maya@studio.example", "A quick question about our order", "Hi Alex,\n\nCould we add two more samples to our order? Let me know what you need from us.\n\nThanks,\nMaya", true, true, .inbox, nil),
            ("personal", "Garden Weekly", "news@garden.example", "Your weekly garden notes", "This week: a little more green.\n\nFresh ideas for the season ahead, from balcony herbs to a weekend in the garden.\n\nThis sample message is displayed as plain text. No images or trackers are loaded.", true, false, .inbox, nil),
            ("cent", "Sophie Martin", "sophie@partner.example", "Thursday meeting", "Hello Alex,\n\nLooking forward to speaking with you on Thursday. I have attached the topics to our calendar invitation.\n\nBest,\nSophie", false, true, .inbox, nil),
            ("personal", "Alex Morgan", "morgan@friends.example", "Dinner this weekend?", "Hey Alex,\n\nAre you free on Saturday? We were thinking about dinner around six.\n\nLet me know!", false, true, .inbox, nil),
            ("personal", "Harbor Outfitters", "offers@harbor.example", "A few things for the weekend", "A small collection for your next adventure.\n\nThis is a sample newsletter. Unsubscribe networking is not enabled in this prototype.", false, false, .inbox, nil),
            ("base", "Studio Notes", "newsletter@studio.example", "Our November newsletter", "A few updates from the studio.\n\nWe are getting ready for the new season and wanted to share what is coming next.", false, false, .inbox, nil),
            ("base", "Unknown sender", "visitor@unknown.example", "Hey", "hey", true, false, .junk, "Sample rule: short generic message from a new sender. Review the context before restoring or blocking."),
            ("personal", "Blank message", "no-reply@unknown.example", "(No subject)", "", true, false, .junk, "Sample rule: no visible message content."),
            ("orders", "Jamie Park", "jamie@partner.example", "Thank you for your help", "Everything arrived safely. Thanks again for the careful packaging!\n\nJamie", false, true, .archive, nil)
        ]
        var messages = rows.enumerated().map { index, row in
            MailMessage(id: "sample-\(index)", accountID: row.0, senderName: row.1, senderAddress: row.2, subject: row.3, body: row.4, date: Date().addingTimeInterval(-Double(index) * 1900), unread: row.5, priority: row.6, folder: row.7, junkReason: row.8)
        }
        for index in accounts.indices {
            accounts[index].lastAttempt = Date()
            accounts[index].lastSuccess = Date().addingTimeInterval(index >= 2 ? -7200 : -60)
        }
        messages[0].receivedAs = accounts[1].aliases.first
        messages[0].attachment = DemoAttachment()
        messages[0].copiedRecipients = ["logistics@partner.example"]
        messages[0].replyTo = "dispatch@partner.example"
        messages[0].body += "\n\nSchedule: https://partner.example/schedule"
        messages.append(MailMessage(accountID: "base", senderName: "Jordan Lee", senderAddress: "jordan@studio.example", subject: "Earlier shipment", body: "Thanks for confirming the previous schedule.", date: Date().addingTimeInterval(-86400), unread: false, folder: .archive))
        return MailSnapshot(accounts: accounts, groups: ["Personal", "Studio", "Office"], messages: messages)
    }
}

struct DemoAttachment: Codable, Hashable {
    var name = "schedule.txt"
    var text = "Sample delivery schedule\nThursday: first shipment\nMonday: remaining items"
}

struct SavedView: Codable, Identifiable {
    var id = UUID()
    var name: String
    var folder: MailFolder
    var accountID: String?
    var group: String?
    var priority: Bool
    var unread: Bool
    var attachments: Bool
    var favoritesOnly: Bool?
    var query: String
}

struct OfflinePack: Codable, Identifiable {
    var id = UUID()
    var name: String
    var date = Date()
    var payload: Data
    var messages: [MailMessage] {
        (try? JSONDecoder().decode([MailMessage].self, from: payload)) ?? []
    }
}

extension MailDraft {
    var recipients: [String] {
        recipient.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

extension MailAccount {
    func sampleStatus(at time: Date) -> String {
        if let issue { return issue.label }
        guard let lastSuccess, time.timeIntervalSince(lastSuccess) < 3600 else { return "Not checked recently" }
        return "Current"
    }
}
