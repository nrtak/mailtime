import Network
import Security
import SwiftUI

@MainActor
private final class MailServerProbe: ObservableObject {
    @Published var busy = false
    @Published var result = ""
    private var connection: NWConnection?
    private var timer: Task<Void, Never>?
    private var attempt = UUID()

    func cancel() {
        attempt = UUID()
        timer?.cancel()
        connection?.cancel()
        connection = nil
        busy = false
    }

    func start(hostname: String, port: UInt16) {
        cancel()
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
        guard host.utf8.count <= 253, host.range(of: "^" + label + "(?:\\." + label + ")+$", options: .regularExpression) != nil,
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            result = "Enter the mail server’s hostname, such as imap.example.com."
            return
        }
        let id = attempt
        let queue = DispatchQueue(label: "MailServerProbe")
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_server_name(options, host)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let serverTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let policy = SecPolicyCreateSSL(true, host as CFString)
            complete(SecTrustSetPolicies(serverTrust, policy) == errSecSuccess && SecTrustEvaluateWithError(serverTrust, nil))
        }, queue)
        let socket = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        busy = true
        result = ""
        connection = socket
        socket.stateUpdateHandler = { [weak self] state in
            let message: String
            switch state {
            case .ready: message = "Encrypted connection verified for \(host) on port \(port)."
            case .failed: message = "Could not verify an encrypted connection to \(host) on port \(port)."
            default: return
            }
            Task { @MainActor in self?.finish(id, message) }
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.finish(id, "The connection timed out. Check the hostname, port, and network.")
        }
        socket.start(queue: queue)
    }

    private func finish(_ id: UUID, _ message: String) {
        guard id == attempt else { return }
        cancel()
        result = message
    }
}

struct MailServerCheck: View {
    @StateObject private var probe = MailServerProbe()
    @State private var hostname = ""
    @State private var port: UInt16 = 993

    var body: some View {
        Form {
            Section("Custom mail server") {
                TextField("Server hostname", text: $hostname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Picker("Connection", selection: $port) {
                    Text("Incoming IMAP · 993").tag(UInt16(993))
                    Text("Outgoing SMTP · 465").tag(UInt16(465))
                }
                Button("Check encrypted connection") { probe.start(hostname: hostname, port: port) }
                    .disabled(hostname.isEmpty)
            }.disabled(probe.busy)
            if probe.busy { ProgressView("Checking server…") }
            if !probe.result.isEmpty { Text(probe.result) }
            Text("This contacts the server you enter and checks its TLS certificate and hostname. No password or mail is sent.").font(.footnote)
        }.navigationTitle("Check mail server")
            .onDisappear { probe.cancel() }
    }
}
