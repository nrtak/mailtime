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

private struct MicrosoftIdentityRecord: Codable {
    let subject: String
    let address: String
}

// This namespace is exclusively for Microsoft personal accounts in the consumers authority.
private enum IdentityKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "EmailClient") + ".microsoft.consumers",
         kSecAttrSynchronizable as String: false]
    }

    static func list() throws -> [(String, String)] {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        var output: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &output)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = output as? [[String: Any]] else { throw IdentityError("Unlock the iPhone to access saved identities.") }
        return rows.compactMap { row -> (String, String)? in
            guard let subject = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let identity = try? JSONDecoder().decode(MicrosoftIdentityRecord.self, from: data),
                  identity.subject == subject else { return nil }
            return (subject, identity.address)
        }.sorted { $0.1 < $1.1 }
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
private final class OutlookSignIn: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    struct Saved: Identifiable { let id: String; let address: String }
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
        do { saved = try IdentityKeychain.list().map { Saved(id: $0.0, address: $0.1) } }
        catch { status = error.localizedDescription }
    }

    func remove(_ id: String) {
        do { try IdentityKeychain.remove(id); reload(); status = "Identity removed from this iPhone." }
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

    func authorize(expected: String?) async {
        guard !busy, let clientID, let bundle = Bundle.main.bundleIdentifier else { return }
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
                "response_mode": "query", "scope": "User.Read", "state": state, "prompt": "select_account",
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
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.urlCredentialStorage = nil
            config.httpCookieStorage = nil
            let http = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
            defer { http.finishTasksAndInvalidate() }
            var exchange = URLRequest(url: URL(string: authority + "token")!)
            exchange.httpMethod = "POST"
            exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let fields = ["client_id": clientID, "redirect_uri": redirect, "code": code,
                          "grant_type": "authorization_code", "code_verifier": verifier]
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            exchange.httpBody = Data(fields.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
            struct Tokens: Decodable { let access_token: String }
            let (tokenData, tokenResponse) = try await http.data(for: exchange)
            guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
                  let tokens = try? JSONDecoder().decode(Tokens.self, from: tokenData),
                  !tokens.access_token.isEmpty else { throw IdentityError("Microsoft did not authorize the connection.") }
            var me = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName")!)
            me.setValue("Bearer " + tokens.access_token, forHTTPHeaderField: "Authorization")
            struct Profile: Decodable { let id: String; let mail: String?; let userPrincipalName: String? }
            let (profileData, profileResponse) = try await http.data(for: me)
            guard (profileResponse as? HTTPURLResponse)?.statusCode == 200,
                  let profile = try? JSONDecoder().decode(Profile.self, from: profileData) else { throw IdentityError("Could not verify the Microsoft identity.") }
            // Personal Graph IDs can be opaque strings. Preserve the complete value as the credential identity.
            guard attempt == activeAttempt, !Task.isCancelled else { return }
            try accept(profileID: profile.id, address: profile.mail ?? profile.userPrincipalName ?? "", expected: expected)
            reload()
            status = "Microsoft identity verified. Mail access has not been requested."
        } catch { status = (error as? IdentityError)?.message ?? "Connection failed. Try again when the iPhone is online." }
    }

    private func accept(profileID: String, address: String, expected: String?) throws {
        guard !profileID.isEmpty, !address.isEmpty else { throw IdentityError("Microsoft returned an incomplete identity.") }
        let subject = profileID
        guard expected == nil || expected == subject else { throw IdentityError("A different Microsoft account was selected. The saved identity was preserved.") }
        try IdentityKeychain.store(MicrosoftIdentityRecord(subject: subject, address: address), reconnecting: expected != nil)
    }
}

struct OutlookIdentityView: View {
    @StateObject private var auth = OutlookSignIn()
    @State private var removing: OutlookSignIn.Saved?
    var body: some View {
        Form {
            Section {
                Text("Verify a personal Microsoft account. This connection requests profile access only.")
                if auth.clientID != nil {
                    Button("Sign in with Microsoft") { Task { await auth.authorize(expected: nil) } }
                } else { Text("This build needs a registered Microsoft client ID to enable sign-in.").font(.caption) }
            }
            ForEach(auth.saved) { item in
                Section {
                    Text(verbatim: item.address)
                    Button("Reconnect") { Task { await auth.authorize(expected: item.id) } }.disabled(auth.clientID == nil)
                    Button("Remove from this iPhone", role: .destructive) { removing = item }
                }
            }
            if auth.busy { ProgressView("Checking identity…") }
            if !auth.status.isEmpty { Text(auth.status) }
        }.navigationTitle("Outlook.com identity").disabled(auth.busy)
            .onAppear { auth.reload() }
            .onDisappear { auth.cancel() }
            .alert("Remove this saved identity?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
                Button("Remove", role: .destructive) { auth.remove(item.id) }
                Button("Cancel", role: .cancel) {}
            }
    }
}
