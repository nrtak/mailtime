import SwiftUI

@main
struct EmailClientApp: App {
    @StateObject private var store = MailStore()
    @StateObject private var lock = MailAppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if lock.locked { MailLockScreen() }
                else { InboxView() }
            }
                .environmentObject(lock)
                .environmentObject(store)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    lock.coverWindows()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    lock.uncoverWindows()
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { lock.activate() }
                    if phase == .background { lock.background() }
                }
                .preferredColorScheme(store.snapshot.preferences.appearance == "Dark" ? .dark : store.snapshot.preferences.appearance == "Light" ? .light : nil)
                .task(id: scenePhase == .active ? store.nextSampleRetry : nil) {
                    guard scenePhase == .active, let deadline = store.nextSampleRetry else { return }
                    do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                    catch { return }
                    await store.retryDueSamples()
                }
                .overlay {
                    if scenePhase != .active {
                        ZStack { Color(.systemBackground).ignoresSafeArea(); Image(systemName: "envelope").font(.system(size: 54)).foregroundStyle(.blue) }
                    }
                }
        }
    }
}

extension View {
    func mailGlass() -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }
}
