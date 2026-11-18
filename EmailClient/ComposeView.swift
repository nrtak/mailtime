import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    @State private var review: [String] = []
    @State private var reviewing = false
    @State private var pendingSend: MailDraft?
    @State private var sendFeedback = ""

    private var account: MailAccount? { store.account(store.snapshot.draft.accountID) }
    private var canSend: Bool {
        guard let account else { return false }
        return account.sendingAddresses.contains(store.snapshot.draft.from) && !store.snapshot.draft.recipients.isEmpty && store.snapshot.draft.recipients.allSatisfy(MailStore.validRecipient) && !store.snapshot.draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Demo compose · nothing will be transmitted", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary)
                    Picker("Account", selection: $store.snapshot.draft.accountID) {
                        Text("Choose an account").tag("")
                        ForEach(store.snapshot.accounts.filter { store.snapshot.draft.composeGroup == nil || $0.group == store.snapshot.draft.composeGroup }) { account in
                            Text(account.name + " · " + account.address).tag(account.id)
                        }
                    }.onChange(of: store.snapshot.draft.accountID) { _, id in
                        store.snapshot.draft.from = store.account(id)?.address ?? ""
                    }
                    Picker("From", selection: $store.snapshot.draft.from) {
                        if account == nil { Text("Choose an account first").tag("") }
                        if let account {
                            if !account.sendingAddresses.contains(store.snapshot.draft.from) {
                                Text("Choose a sending address").tag(store.snapshot.draft.from)
                            }
                            ForEach(account.sendingAddresses, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    TextField("Recipients, separated by commas", text: $store.snapshot.draft.recipient).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Subject", text: $store.snapshot.draft.subject)
                }
                if !sendFeedback.isEmpty { Text(sendFeedback).foregroundStyle(.secondary) }
                if let error = store.storageError {
                    Section { Text(error); Button("Retry save") { store.save() } }
                }
                Section("Attachment") {
                    if let file = store.snapshot.draft.attachment {
                        Text(file.name)
                        Button("Remove attachment") { store.snapshot.draft.attachment = nil }
                    } else {
                        Button("Attach sample schedule") { store.snapshot.draft.attachment = DemoAttachment() }
                    }
                }
                Section("Message") {
                    Menu("Insert template") {
                        ForEach(store.snapshot.templates ?? []) { template in
                            Button(template.name) {
                                if !store.snapshot.draft.body.isEmpty { store.snapshot.draft.body += "\n\n" }
                                store.snapshot.draft.body += template.body
                            }
                        }
                    }.disabled(store.snapshot.templates?.isEmpty ?? true)
                    TextEditor(text: $store.snapshot.draft.body).frame(minHeight: 260)
                }
                if let signature = store.snapshot.draft.signature, !signature.isEmpty {
                    Section("Signature") { Text(verbatim: signature) }
                }
                Section {
                    Text("Drafts are stored on this device. Sending places it in Demo Sent only. Sample aliases cannot be edited into arbitrary sending addresses.").font(.caption).foregroundStyle(.secondary)
                    Button("Discard draft", role: .destructive) { confirmDiscard = true }
                }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Save & close") { if store.flushDraft() { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Demo Send") {
                    let draft = store.snapshot.draft
                    pendingSend = draft
                    review = ["From: " + draft.from, "To: " + draft.recipients.joined(separator: ", ")] + store.preSendChecks()
                    reviewing = true
                }.disabled(!canSend) }
            }
            .onChange(of: store.snapshot.draft.from, initial: true) { _, address in
                store.snapshot.draft.signature = account?.signatures?[address]
            }
            .onChange(of: store.snapshot.draft) { _, _ in store.scheduleDraftSave() }
            .alert("Save a copy to Demo Sent?", isPresented: $reviewing) {
                Button("Keep editing", role: .cancel) { pendingSend = nil }
                Button("Confirm Demo Send") {
                    guard let confirmed = pendingSend else { return }
                    pendingSend = nil
                    if store.sendDemo(confirmed: confirmed) { dismiss() }
                    else { sendFeedback = "The message was not sent. Check the draft and try again." }
                }
            } message: { Text(review.joined(separator: "\n\n")) }
            .interactiveDismissDisabled(store.storageError != nil)
            .onDisappear { store.flushDraft() }
            .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard draft", role: .destructive) { if store.discardDraft() { dismiss() } }
            }
        }
    }
}

private struct DraftLabel: View {
    let draft: MailDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: draft.subject.isEmpty ? "(No subject)" : draft.subject)
            Text(verbatim: draft.from.isEmpty ? "Choose a sending address" : draft.from).font(.caption)
        }
    }
}

struct DraftList: View {
    @EnvironmentObject private var store: MailStore
    let accountID: String?
    let group: String?
    @State private var composing = false

    var body: some View {
        List {
            if store.snapshot.draft.isEmpty && (store.snapshot.parkedDrafts ?? []).isEmpty {
                ContentUnavailableView("No saved drafts", systemImage: "doc.text")
            }
            if !store.snapshot.draft.isEmpty {
                Button { composing = true } label: { DraftLabel(draft: store.snapshot.draft) }
            }
            ForEach(Array((store.snapshot.parkedDrafts ?? []).enumerated()), id: \.offset) { index, draft in
                Button { composing = store.resumeDraft(at: index) } label: { DraftLabel(draft: draft) }
            }
            if let error = store.storageError { Text(error) }
        }.navigationTitle("All drafts")
            .toolbar {
                Button("New message", systemImage: "square.and.pencil") {
                    composing = store.prepareCompose(accountID: accountID, group: group)
                }
            }
            .sheet(isPresented: $composing) { ComposeView() }
    }
}
