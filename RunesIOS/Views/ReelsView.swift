import SwiftUI
import WebKit

// Reels: instagram.com's Reels page, full screen, moved through from the band. The page
// keeps its sign-in in the app's own website data, so Instagram asks once. Touch works as
// it does in Safari; the band's gestures run `ReelsScript` in the page.

struct ReelsScreen: View {
    @ObservedObject var store: ReelsStore
    @State private var showSettings = false
    @State private var appeared = false
    @StateObject private var web = ReelsWeb()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ReelsWebView(web: web)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) { flash }
            .background(Color.paper)
            .navigationTitle("Reels").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { web.goToReels() } label: { LucideIcon(.rotateCcw, size: 18).frame(width: 36, height: 36) }
                        .accessibilityLabel("Back to Reels")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { LucideIcon(.settings, size: 19).frame(width: 36, height: 36) }
                        .accessibilityLabel("Reels settings")
                }
            }
            .sheet(isPresented: $showSettings) { ReelsSettingsScreen(store: store, signOut: web.signOut) }
            // Watching, not touching: the screen must not dim between reels.
            .onAppear {
                appeared = true
                UIApplication.shared.isIdleTimerDisabled = true
                store.onCommand = { [weak web] command in web?.run(command) { store.report(command, result: $0) } }
                store.onScreen = scenePhase == .active
            }
            .onDisappear {
                appeared = false
                UIApplication.shared.isIdleTimerDisabled = false
                store.onScreen = false; store.onCommand = nil
                web.pauseAll()
            }
            .onChange(of: scenePhase) { _, phase in
                store.onScreen = appeared && phase == .active
                if phase != .active { web.pauseAll() }
            }
    }

    /// The last command, for a moment, so a gesture that found nothing says so.
    private var flash: some View {
        Group {
            if let flash = store.flash {
                Text(flash.text).font(.label).foregroundStyle(Color.paper)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.ink.opacity(0.85)))
                    .padding(.top, 12)
                    .transition(.opacity)
                    .id(flash.id)
                    .task(id: flash.id) {
                        try? await Task.sleep(for: .milliseconds(1200))
                        withAnimation(.standard) { if store.flash?.id == flash.id { store.flash = nil } }
                    }
            }
        }
        .animation(.standard, value: store.flash)
        .allowsHitTesting(false)
    }
}

/// Owns the web view, so it outlives SwiftUI redrawing the screen.
@MainActor
final class ReelsWeb: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        // Reels play in the page, with sound, without a tap first.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = ReelsScript.userAgent
        #if DEBUG
        // Safari → Develop can inspect the page when a script stops finding the reel.
        view.isInspectable = true
        #endif
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.load(URLRequest(url: ReelsScript.reelsURL))
    }

    func run(_ command: ReelsCommand, done: @escaping (String?) -> Void) {
        view.evaluateJavaScript(ReelsScript.source(for: command)) { result, _ in done(result as? String) }
    }

    func pauseAll() { view.evaluateJavaScript(ReelsScript.pauseAll) }

    func goToReels() { view.load(URLRequest(url: ReelsScript.reelsURL)) }

    /// Forgets Instagram's sign-in and anything else it stored, then shows its sign-in page.
    func signOut() {
        let store = view.configuration.websiteDataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            let instagram = records.filter { $0.displayName.contains("instagram") || $0.displayName.contains("facebook") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: instagram) { self?.goToReels() }
        }
    }

    /// Links that would open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// Instagram and its Facebook sign-in stay in the page; any other link opens in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, let host = url.host?.lowercased() else { return .allow }
        let kept = ["instagram.com", "facebook.com", "fbcdn.net", "cdninstagram.com"]
        if kept.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .allow }
        await UIApplication.shared.open(url)
        return .cancel
    }
}

private struct ReelsWebView: UIViewRepresentable {
    let web: ReelsWeb
    func makeUIView(context: Context) -> WKWebView { web.view }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct ReelsSettingsScreen: View {
    @ObservedObject var store: ReelsStore
    var signOut: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var choosing: ReelsCommand?
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    Block {
                        ForEach(Array(ReelsCommand.allCases.enumerated()), id: \.element) { index, command in
                            if index > 0 { Hairline(delay: 0.04 * Double(index)) }
                            TriggerRow(title: command.title, detail: command.detail,
                                       steps: store.controls.trigger(for: command)?.steps) { choosing = command }
                        }
                    } header: {
                        Heading("Gestures")
                    } footer: {
                        Note("A gesture or a combo each. While Reels is on screen they move through reels, and mappings that use their gestures are off. With the phone locked or Reels closed, your mappings have them again.")
                    }
                    Note("Reels is Instagram’s own website, signed in inside Runes. Runes sees nothing of your account; the gestures only scroll and press its buttons. If Instagram changes its page, a gesture may stop finding the reel until Runes is updated.")
                    Button("Sign out of Instagram") { signingOut = true }.buttonStyle(.quiet)
                        .confirmationDialog("Sign out of Instagram?", isPresented: $signingOut, titleVisibility: .visible) {
                            Button("Sign out", role: .destructive) { signOut(); dismiss() }
                        } message: { Text("Instagram forgets this phone, and asks you to sign in next time.") }
                }
                .padding(.horizontal, Metric.gutter).padding(.top, 8).padding(.bottom, 40)
            }
            .page()
            .navigationTitle("Reels settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.label) } }
            .sheet(item: $choosing) { command in
                let current = store.controls.trigger(for: command)
                let others = ReelsCommand.allCases.filter { $0 != command }
                TriggerSheet(title: command.title, caption: command.detail, rules: ReelsControls.rules,
                             steps: current?.steps ?? [], intervalMs: current?.intervalMs ?? ComboRules.defaultTime,
                             taken: Set(others.compactMap(store.controls.gesture)),
                             feed: RunesIOSApp.snapshotName == nil ? .shared : nil,
                             note: { steps in
                    others.first { store.controls.trigger(for: $0)?.steps == steps }.map { "\($0.title) uses this; they’ll swap." }
                }, save: { steps, interval in
                    store.setTrigger(steps.isEmpty ? nil : CommandTrigger(steps: steps, intervalMs: interval), for: command)
                })
            }
        }
        .tint(Color.ink)
    }
}
