import SwiftUI
import UserNotifications
import PhotosUI
import Vision
import ImageIO

struct MessageView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    let messageID: String
    @State private var composeOpen = false

    private func reply(_ mail: MailMessage, all: Bool) {
        guard let account = store.account(mail.accountID) else { return }
        if store.snapshot.draft.isEmpty {
            let addresses = [mail.replyTo ?? mail.senderAddress] + (all ? mail.copiedRecipients ?? [] : [])
            let from = account.sendingAddresses.first { $0 == mail.receivedAs }
                ?? (mail.receivedAs == nil && account.aliases.isEmpty ? account.address : "")
            store.snapshot.draft = MailDraft(accountID: account.id, from: from, recipient: addresses.joined(separator: ", "), subject: mail.subject.lowercased().hasPrefix("re:") ? mail.subject : "Re: " + mail.subject, originalAccount: account.id, replyAll: all)
            store.save()
        }
        composeOpen = true
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
                        MessageActions(mail: mail)
                        if let file = store.readableAttachment(for: mail) {
                            DisclosureGroup(file.name) { Text(verbatim: file.text) }
                        }
                        NavigationLink("Inspect a link or QR code") { LinkInspector(initial: mail.body) }
                        if let reason = mail.junkReason, mail.folder == .junk {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("Why this is in Junk", systemImage: "exclamationmark.shield").font(.headline)
                                Text(reason).font(.subheadline)
                                Button("Restore to Inbox") { store.move(mail.id, to: .inbox); dismiss() }.buttonStyle(.bordered)
                            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                        }
                        Label("Plain text · remote content never loaded", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        // A Text view never interprets message HTML or executes scripts.
                        Text(verbatim: mail.body.isEmpty ? "This message has no visible content." : mail.body)
                            .font(.body).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(22)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { store.update(mail.id) { $0.unread.toggle() } } label: { Image(systemName: mail.unread ? "envelope.open" : "envelope.badge") }.accessibilityLabel(mail.unread ? "Mark read" : "Mark unread")
                        Spacer()
                        Button { store.update(mail.id) { $0.priority.toggle() } } label: { Image(systemName: mail.priority ? "star.fill" : "star") }.accessibilityLabel(mail.priority ? "Remove from Priority" : "Move to Priority")
                        Spacer()
                        Button { store.move(mail.id, to: mail.folder == .junk ? .inbox : .junk); dismiss() } label: { Image(systemName: mail.folder == .junk ? "tray.and.arrow.up" : "exclamationmark.shield") }.accessibilityLabel(mail.folder == .junk ? "Restore to Inbox" : "Move to Junk")
                        Spacer()
                        Button { store.move(mail.id, to: .archive); dismiss() } label: { Image(systemName: "archivebox") }.accessibilityLabel("Archive")
                        Spacer()
                        Menu("Reply", systemImage: "arrowshape.turn.up.left") {
                            Button(store.snapshot.draft.isEmpty ? "Reply" : "Resume existing draft") { reply(mail, all: false) }
                            if store.snapshot.draft.isEmpty && !(mail.copiedRecipients ?? []).isEmpty {
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
    private var reminderID: String { "mail-action-" + mail.id }

    var body: some View {
        DisclosureGroup(mail.action ?? "Add to action queue") {
            Picker("Action", selection: Binding(get: { mail.action ?? "None" }, set: { status in
                if status == "Done" || status == "None" { cancelReminder() }
                store.update(mail.id) { $0.action = status == "None" ? nil : status }
            })) {
                ForEach(["None", "Needs reply", "Waiting", "Done"], id: \.self) { Text($0).tag($0) }
            }.disabled(scheduling)
            if ["Needs reply", "Waiting"].contains(mail.action ?? "") {
                DatePicker("Remind me", selection: $time, in: Date()...)
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
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        center.removeDeliveredNotifications(withIdentifiers: [reminderID])
        store.update(mail.id) { $0.reminder = nil }
        feedback = ""
    }

    @MainActor private func schedule() async {
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
            let content = UNMutableNotificationContent()
            content.title = "Mail reminder"
            content.body = "Review your action queue."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, target.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger))
            guard store.message(mail.id)?.accountID == mail.accountID else {
                center.removePendingNotificationRequests(withIdentifiers: [reminderID])
                center.removeDeliveredNotifications(withIdentifiers: [reminderID])
                return
            }
            store.update(mail.id) { $0.reminder = target }
            feedback = "Reminder scheduled."
        } catch { feedback = error.localizedDescription }
    }
}

struct LinkInspector: View {
    let initial: String
    @State private var input = ""
    @State private var photo: PhotosPickerItem?
    @State private var feedback = ""

    private var destinations: [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { match in
            guard let range = Range(match.range, in: input) else { return nil }
            let literal = String(input[range])
            guard literal.lowercased().hasPrefix("https://") || literal.lowercased().hasPrefix("http://"),
                  let url = URL(string: literal), url.host != nil, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    var body: some View {
        Form {
            Section("Inspect on this iPhone") {
                TextField("Paste a web address or text", text: $input, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                PhotosPicker("Choose QR image", selection: $photo, matching: .images)
                if !feedback.isEmpty { Text(feedback).font(.caption) }
            }
            Section {
                if destinations.isEmpty { Text("No explicit HTTP or HTTPS address found.") }
                ForEach(destinations, id: \.absoluteString) { url in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: url.host(percentEncoded: true) ?? "").bold()
                        Text(verbatim: url.absoluteString).font(.caption).textSelection(.enabled)
                        if url.user != nil || url.password != nil { Text("This address contains sign-in information before the host.") }
                        if url.scheme?.lowercased() == "http" { Text("Unencrypted HTTP address") }
                    }
                }
            } header: { Text("Destinations") } footer: { Text("Inspection reads the address locally. A shortened link or a redirect may lead to another site.") }
        }.navigationTitle("Link inspector")
            .onAppear { if input.isEmpty { input = initial } }
            .task(id: photo) {
                guard let photo else { return }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self), data.count <= 24 * 1024 * 1024 else {
                        feedback = "Choose a smaller image."; return
                    }
                    let values = try await Self.decodeQR(data)
                    try Task.checkCancellation()
                    input = values.joined(separator: "\n")
                    feedback = values.isEmpty ? "No QR code found." : "Decoded on this device."
                } catch { if !Task.isCancelled { feedback = "Could not read that image." } }
            }
    }

    nonisolated private static func decodeQR(_ data: Data) async throws -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}
