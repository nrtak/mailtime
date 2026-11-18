import AuthenticationServices
import CryptoKit
import Security
import SwiftUI
import UIKit

private struct IdentityError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct MicrosoftIdentityRecord: Codable {
    let subject: String
    var address: String
    var refreshToken: String?
    var issue: String?
    var pinned: Bool?
    var lastCheck: Date?

    mutating func signedIn(address: String, refreshToken: String) {
        self.address = address
        self.refreshToken = refreshToken
        if issue == nil { issue = "Waiting for an inbox check." }
    }

    mutating func checkedInbox(at date: Date) {
        lastCheck = date
        issue = nil
    }
}

// This namespace is exclusively for Microsoft personal accounts in the consumers authority.
private enum IdentityKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "EmailClient") + ".microsoft.consumers",
         kSecAttrSynchronizable as String: false]
    }

    static func list() throws -> [MicrosoftIdentityRecord] {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = output as? [[String: Any]] else { throw IdentityError("Unlock the iPhone to access saved identities.") }
        return rows.compactMap { row -> MicrosoftIdentityRecord? in
            guard let subject = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let identity = try? JSONDecoder().decode(MicrosoftIdentityRecord.self, from: data),
                  identity.subject == subject else { return nil }
            return identity
        }.sorted { $0.address < $1.address }
    }

    static func existingRecord(_ id: String) throws -> MicrosoftIdentityRecord? {
        var request = query
        request[kSecAttrAccount as String] = id
        request[kSecReturnData as String] = true
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else { throw IdentityError("Unlock the iPhone and try again.") }
        let record = try JSONDecoder().decode(MicrosoftIdentityRecord.self, from: data)
        guard record.subject == id else { throw IdentityError("Saved account does not match.") }
        return record
    }

    static func record(_ id: String) throws -> MicrosoftIdentityRecord {
        guard let record = try existingRecord(id) else { throw IdentityError("This account is no longer on this iPhone.") }
        return record
    }

    static func store(_ identity: MicrosoftIdentityRecord, reconnecting: Bool) throws {
        var key = query
        key[kSecAttrAccount as String] = identity.subject
        let attrs: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(identity),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(key as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound && !reconnecting {
            status = SecItemAdd(key.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw IdentityError("Could not save the identity on this iPhone.") }
    }

    static func remove(_ id: String) throws {
        var key = query
        key[kSecAttrAccount as String] = id
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError("Could not remove the identity.") }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private final class SignInCallback {
    private let lock = NSLock()
    private var pending: CheckedContinuation<URL, Error>?
    init(_ pending: CheckedContinuation<URL, Error>) { self.pending = pending }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor
final class OutlookSignIn: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    struct Saved: Identifiable {
        let id: String
        let address: String
        let issue: String?
        let pinned: Bool
        let lastCheck: Date?
    }
    @Published private(set) var reading: String?
    @Published var saved: [Saved] = []
    @Published var busy = false
    @Published var status = ""
    private var session: ASWebAuthenticationSession?
    private var activeAttempt = UUID()
    private var anchor: UIWindow?
    var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MailMicrosoftClientID") as? String,
              UUID(uuidString: raw) != nil else { return nil }
        return raw
    }

    func reload() {
        do { saved = try IdentityKeychain.list().map { Saved(id: $0.subject, address: $0.address, issue: $0.issue ?? ($0.refreshToken == nil ? "Reconnect to enable inbox access." : nil), pinned: $0.pinned == true, lastCheck: $0.lastCheck) } }
        catch { status = error.localizedDescription }
    }

    func togglePin(_ id: String) {
        guard !busy, reading == nil else { return }
        do {
            var record = try IdentityKeychain.record(id)
            record.pinned = record.pinned != true
            try IdentityKeychain.store(record, reconnecting: true)
            reload()
        } catch { status = error.localizedDescription }
    }

    func remove(_ id: String) {
        guard reading == nil, !busy else { return }
        do { try OutlookCache.remove(id); try IdentityKeychain.remove(id); reload(); status = "Account removed from this iPhone." }
        catch { status = error.localizedDescription }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor! }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw IdentityError("Could not start a secure sign-in.") }
        return base64url(Data(bytes))
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func cancel() {
        activeAttempt = UUID()
        session?.cancel()
    }

    @discardableResult
    func connect(expected: String?) async -> OutlookCache? {
        guard let subject = await authorize(expected: expected) else { return nil }
        do { return try await refresh(subject) }
        catch { status = error.localizedDescription; return nil }
    }

    private func authorize(expected: String?) async -> String? {
        guard !busy, reading == nil, let clientID, let bundle = Bundle.main.bundleIdentifier else { return nil }
        let attempt = UUID()
        activeAttempt = attempt
        busy = true
        status = ""
        defer { busy = false; session = nil; anchor = nil }
        do {
            let scheme = bundle + ".signin"
            let redirect = scheme + "://auth/callback"
            let verifier = try randomValue()
            let state = try randomValue()
            let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
            let authority = "https://login.microsoftonline.com/consumers/oauth2/v2.0/"
            var auth = URLComponents(string: authority + "authorize")!
            auth.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code",
                "response_mode": "query", "scope": "User.Read Mail.Read offline_access", "state": state, "prompt": "select_account",
                "code_challenge": challenge, "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
            anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })
            guard anchor != nil, let authURL = auth.url else { throw IdentityError("Open the app to sign in.") }
            let returned: URL = try await withCheckedThrowingContinuation { continuation in
                let reply = SignInCallback(continuation)
                let web = ASWebAuthenticationSession(url: authURL, callback: .customScheme(scheme)) { url, _ in
                    if let url { reply.finish(.success(url)) }
                    else { reply.finish(.failure(IdentityError("Sign-in ended."))) }
                }
                self.session = web
                web.presentationContextProvider = self
                web.prefersEphemeralWebBrowserSession = true
                if !web.start() { reply.finish(.failure(IdentityError("Could not open Microsoft sign-in."))) }
            }
            guard let callback = URLComponents(url: returned, resolvingAgainstBaseURL: false),
                  callback.scheme?.caseInsensitiveCompare(scheme) == .orderedSame, callback.host == "auth", callback.path == "/callback",
                  callback.port == nil, callback.user == nil, callback.password == nil, callback.fragment == nil else {
                throw IdentityError("Unexpected sign-in callback.")
            }
            let items = callback.queryItems ?? []
            let states = items.filter { $0.name == "state" }, codes = items.filter { $0.name == "code" }
            guard states.count == 1, states.first?.value == state, codes.count == 1,
                  let code = codes.first?.value, !code.isEmpty, !items.contains(where: { $0.name == "error" }) else {
                throw IdentityError("Microsoft sign-in could not be verified.")
            }
            let http = Self.transport()
            defer { http.finishTasksAndInvalidate() }
            let exchange = Self.tokenRequest(["client_id": clientID, "redirect_uri": redirect, "code": code,
                          "grant_type": "authorization_code", "code_verifier": verifier])
            let (tokenData, tokenResponse) = try await http.data(for: exchange)
            guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
                  let tokens = try? JSONDecoder().decode(Tokens.self, from: tokenData),
                  !tokens.access_token.isEmpty, let renewal = tokens.refresh_token, !renewal.isEmpty else { throw IdentityError("Microsoft did not authorize the connection.") }
            var me = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName")!)
            me.setValue("Bearer " + tokens.access_token, forHTTPHeaderField: "Authorization")
            struct Profile: Decodable { let id: String; let mail: String?; let userPrincipalName: String? }
            let (profileData, profileResponse) = try await http.data(for: me)
            guard (profileResponse as? HTTPURLResponse)?.statusCode == 200,
                  let profile = try? JSONDecoder().decode(Profile.self, from: profileData) else { throw IdentityError("Could not verify the Microsoft identity.") }
            // Personal Graph IDs can be opaque strings. Preserve the complete value as the credential identity.
            guard attempt == activeAttempt, !Task.isCancelled else { return nil }
            try accept(profileID: profile.id, address: profile.mail ?? profile.userPrincipalName ?? "", expected: expected, refreshToken: renewal)
            reload()
            return profile.id
        } catch {
            status = (error as? IdentityError)?.message ?? "Connection failed. Try again when the iPhone is online."
            return nil
        }
    }

    private func accept(profileID: String, address: String, expected: String?, refreshToken: String) throws {
        guard !profileID.isEmpty, !address.isEmpty else { throw IdentityError("Microsoft returned an incomplete identity.") }
        let subject = profileID
        guard expected == nil || expected == subject else { throw IdentityError("A different Microsoft account was selected. The saved identity was preserved.") }
        var record = try IdentityKeychain.existingRecord(subject) ?? MicrosoftIdentityRecord(subject: subject, address: address)
        record.signedIn(address: address, refreshToken: refreshToken)
        try IdentityKeychain.store(record, reconnecting: expected != nil)
    }
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
    }

    private static func transport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static func tokenRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
        return request
    }

    func refresh(_ id: String) async throws -> OutlookCache {
        guard !busy, reading == nil else { throw IdentityError("An account connection is already in progress.") }
        guard let clientID else { throw IdentityError("This build needs a Microsoft client ID.") }
        reading = id
        status = ""
        defer { reading = nil }
        var record = try IdentityKeychain.record(id)
        let http = Self.transport()
        defer { http.finishTasksAndInvalidate() }
        do {
            guard let token = record.refreshToken else { throw IdentityError("Reconnect to enable inbox access.") }
            let exchange = Self.tokenRequest(["client_id": clientID, "refresh_token": token, "grant_type": "refresh_token"])
            let (data, response) = try await http.data(for: exchange)
            struct OAuthError: Decodable { let error: String }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let tokens = try? JSONDecoder().decode(Tokens.self, from: data), !tokens.access_token.isEmpty else {
                let code = (try? JSONDecoder().decode(OAuthError.self, from: data))?.error
                if code == "invalid_grant" || code == "interaction_required" { throw IdentityError("Microsoft requires you to reconnect this account.") }
                throw IdentityError("Microsoft sign-in is unavailable. Try refreshing again later.")
            }
            if let next = tokens.refresh_token, !next.isEmpty {
                record.refreshToken = next
                try IdentityKeychain.store(record, reconnecting: true)
            }
            let cache = try await OutlookCache.fetch(id, token: tokens.access_token, http: http)
            try Task.checkCancellation()
            try cache.write()
            record.checkedInbox(at: cache.checked)
            try IdentityKeychain.store(record, reconnecting: true)
            reload()
            return cache
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let problem = (error as? IdentityError)?.message ?? (error is URLError
                ? "Couldn’t reach Microsoft. Check your connection and try again."
                : "Couldn’t finish reading or saving this inbox. Try again.")
            record.issue = problem
            try? IdentityKeychain.store(record, reconnecting: true)
            reload()
            throw IdentityError(problem)
        }
    }

}

struct OutlookIdentityView: View {
    @EnvironmentObject private var auth: OutlookSignIn
    @State private var removing: OutlookSignIn.Saved?
    var body: some View {
        Form {
            Section {
                Text("Connect a personal Outlook.com account to read the 50 most recent inbox messages directly from Microsoft.")
                if auth.clientID != nil {
                    Button("Sign in with Microsoft") { Task { await auth.connect(expected: nil) } }
                } else { Text("This build needs a registered Microsoft client ID to enable sign-in.").font(.caption) }
            }
            ForEach(auth.saved) { item in
                Section {
                    NavigationLink { OutlookReader(item: item) } label: { Label(item.address, systemImage: "tray") }
                    if let issue = item.issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption) }
                    Button(item.pinned ? "Unpin inbox" : "Pin inbox") { auth.togglePin(item.id) }
                    Button("Reconnect") { Task { await auth.connect(expected: item.id) } }.disabled(auth.clientID == nil)
                    Button("Remove from this iPhone", role: .destructive) { removing = item }
                }
            }
            if auth.busy { ProgressView("Checking identity…") }
            if auth.reading != nil { ProgressView("Checking inbox…") }
            if !auth.status.isEmpty { Text(auth.status) }
        }.navigationTitle("Outlook inboxes").disabled(auth.busy || auth.reading != nil)
            .onAppear { auth.reload() }
            .onDisappear { auth.cancel() }
            .alert("Remove this account and its downloaded mail?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
                Button("Remove", role: .destructive) { auth.remove(item.id) }
                Button("Cancel", role: .cancel) {}
            }
    }
}

struct OutlookLetter: Codable, Identifiable {
    let id: String
    let conversationID: String?
    let subject: String
    let sender: String
    let address: String
    let received: Date
    let text: String
    let previewOnly: Bool
}

struct OutlookCache: Codable {
    let owner: String
    let checked: Date
    let messages: [OutlookLetter]

    private static func location(_ id: String, create: Bool) throws -> URL {
        let manager = FileManager.default
        var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
            .appendingPathComponent("Outlook", isDirectory: true)
        if create {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
        }
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    static func read(_ id: String) throws -> Self? {
        do {
            let loaded = try JSONDecoder().decode(Self.self, from: Data(contentsOf: try location(id, create: false)))
            guard loaded.owner == id else { throw CocoaError(.coderReadCorrupt) }
            return loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func write() throws {
        try JSONEncoder().encode(self).write(to: Self.location(owner, create: true), options: [.atomic, .completeFileProtection])
    }

    static func remove(_ id: String) throws {
        do { try FileManager.default.removeItem(at: location(id, create: false)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
    }

    static func approvedPage(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host?.lowercased() == "graph.microsoft.com" &&
            parts.port == nil && parts.user == nil && parts.password == nil && parts.fragment == nil &&
            parts.path.hasPrefix("/v1.0/")
    }

    static func fetch(_ owner: String, token: String, http: URLSession) async throws -> Self {
        struct Sender: Decodable {
            struct Address: Decodable { let name: String?; let address: String? }
            let emailAddress: Address?
        }
        struct Body: Decodable { let contentType: String; let content: String }
        struct Row: Decodable {
            let id: String
            let conversationId: String?
            let receivedDateTime: String
            let from: Sender?
            let subject: String?
            let body: Body?
            let bodyPreview: String?
        }
        struct Page: Decodable {
            let value: [Row]
            let next: URL?
            enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
        }
        var query = URLComponents(string: "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages")!
        query.queryItems = [URLQueryItem(name: "$top", value: "10"),
                            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
                            URLQueryItem(name: "$select", value: "id,conversationId,receivedDateTime,from,subject,body,bodyPreview")]
        let dates = ISO8601DateFormatter()
        let fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var next = query.url
        var pages = Set<URL>()
        var seen = Set<String>()
        var letters: [OutlookLetter] = []
        while let url = next, letters.count < 50 {
            try Task.checkCancellation()
            guard approvedPage(url), pages.insert(url).inserted, pages.count <= 20 else {
                throw IdentityError("Microsoft returned an unexpected page. Refresh again.")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("outlook.body-content-type=\"text\", IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
            let (data, response) = try await http.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: break
            case 401, 403: throw IdentityError("Microsoft requires you to reconnect this account.")
            case 429: throw IdentityError("Microsoft asked this inbox to wait. Try refreshing later.")
            default: throw IdentityError("Microsoft couldn’t finish the inbox refresh. Try again later.")
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            for row in page.value where letters.count < 50 {
                guard !row.id.isEmpty, let date = fractions.date(from: row.receivedDateTime) ?? dates.date(from: row.receivedDateTime) else {
                    throw IdentityError("Microsoft returned an incomplete message. Refresh again.")
                }
                guard seen.insert(row.id).inserted else { continue }
                let full = row.body.flatMap { $0.contentType.lowercased() == "text" ? $0.content : nil }
                letters.append(OutlookLetter(id: row.id, conversationID: row.conversationId, subject: row.subject ?? "",
                    sender: row.from?.emailAddress?.name ?? "", address: row.from?.emailAddress?.address ?? "",
                    received: date, text: full ?? row.bodyPreview ?? "", previewOnly: full == nil))
            }
            next = page.next
        }
        return Self(owner: owner, checked: Date(), messages: letters.sorted { $0.received > $1.received })
    }
}

struct OutlookReader: View {
    @EnvironmentObject private var auth: OutlookSignIn
    let item: OutlookSignIn.Saved
    @State private var cache: OutlookCache?
    @State private var errorText: String?
    private var issue: String? { errorText ?? auth.saved.first { $0.id == item.id }?.issue }

    private func refresh() async {
        do { cache = try await auth.refresh(item.id); errorText = nil }
        catch { if !Task.isCancelled { errorText = error.localizedDescription } }
    }

    var body: some View {
        List {
            Section {
                Text(verbatim: item.address)
                if let cache { Text("Last successful check · " + cache.checked.formatted()).font(.caption) }
                if let issue { Label(issue, systemImage: "exclamationmark.triangle").font(.subheadline) }
                if auth.reading == item.id { ProgressView("Checking inbox…") }
                if auth.busy { ProgressView("Connecting to Microsoft…") }
                Button("Reconnect with Microsoft") {
                    Task {
                        errorText = nil
                        if let downloaded = await auth.connect(expected: item.id) { cache = downloaded }
                    }
                }.disabled(auth.busy || auth.reading != nil || auth.clientID == nil)
                if !auth.status.isEmpty { Text(verbatim: auth.status).font(.caption) }
            }
            if let cache {
                if cache.messages.isEmpty { Text("The inbox was empty at the last successful check.") }
                ForEach(cache.messages) { mail in
                    NavigationLink {
                        OutlookConversation(mail: mail, messages: cache.messages)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: mail.sender.isEmpty ? mail.address : mail.sender).font(.headline)
                            if !mail.sender.isEmpty { Text(verbatim: mail.address).font(.caption).foregroundStyle(.secondary) }
                            Text(verbatim: mail.subject.isEmpty ? "(No subject)" : mail.subject).lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Outlook inbox")
        .refreshable { await refresh() }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(auth.busy || auth.reading != nil || auth.clientID == nil)
        }
        .task(id: item.id) {
            do { cache = try OutlookCache.read(item.id) } catch { errorText = "The downloaded inbox couldn’t be opened." }
            if cache == nil || Date().timeIntervalSince(cache?.checked ?? .distantPast) > 300 { await refresh() }
        }
    }
}

private struct OutlookConversation: View {
    let mail: OutlookLetter
    let messages: [OutlookLetter]
    private func content(_ letter: OutlookLetter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: letter.address)
            Text(letter.received.formatted()).font(.caption)
            if letter.previewOnly { Text("Message preview").font(.caption.weight(.semibold)) }
            Text(verbatim: letter.text.isEmpty ? "No visible text." : letter.text).textSelection(.enabled)
        }
    }
    var body: some View {
        let others = messages.filter { $0.id != mail.id && mail.conversationID?.isEmpty == false && $0.conversationID == mail.conversationID }
        List {
            Section { content(mail) } header: { Text(verbatim: mail.subject) }
            ForEach(others) { letter in
                DisclosureGroup { content(letter) } label: { Text(verbatim: letter.sender.isEmpty ? letter.address : letter.sender) }
            }
        }.navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
    }
}
