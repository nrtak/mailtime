import SwiftUI

struct ComposeView: View {
    @EnvironmentObject private var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    @State private var review: [String] = []
    @State private var reviewing = false

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
                        ForEach(store.snapshot.accounts) { Text($0.name).tag($0.id) }
                    }.onChange(of: store.snapshot.draft.accountID) { _, id in
                        store.snapshot.draft.from = ""
                    }
                    Picker("From", selection: $store.snapshot.draft.from) {
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
                    TextEditor(text: $store.snapshot.draft.body).frame(minHeight: 260)
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
                    review = store.preSendChecks()
                    if review.isEmpty { if store.sendDemo() { dismiss() } }
                    else { reviewing = true }
                }.disabled(!canSend) }
            }
            .onChange(of: store.snapshot.draft) { _, _ in store.scheduleDraftSave() }
            .alert("Review before sending", isPresented: $reviewing) {
                Button("Keep editing", role: .cancel) {}
                Button("Demo Send") { if store.sendDemo() { dismiss() } }
            } message: { Text(review.joined(separator: "\n\n")) }
            .interactiveDismissDisabled(store.storageError != nil)
            .onDisappear { store.flushDraft() }
            .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard draft", role: .destructive) { if store.discardDraft() { dismiss() } }
            }
        }
    }
}
