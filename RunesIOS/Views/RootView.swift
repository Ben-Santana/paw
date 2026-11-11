import SwiftUI

/// Binds the live controller to the value-driven screens.
struct RootView: View {
    @ObservedObject var controller: SessionController
    @State private var showSettings = false
    @State private var showMappings = false
    @State private var showApplications = false
    /// The app shown full screen, kept while its cover slides away so it doesn't go blank.
    @State private var openedApp: RunesApp = .workouts
    @State private var showApp = false
    /// An app a widget asked for while another full-screen page was up; shown once that page has gone.
    @State private var queuedApp: RunesApp?
    @State private var showSetup = false
    @State private var restartBandSetup: UUID?
    @ObservedObject private var links = AppLinkRouter.shared

    private var status: BandStatus {
        BandStatus(controller.snapshot, setupComplete: controller.setupComplete, relayStatus: controller.relayStatus)
    }

    var body: some View {
        Group {
            if controller.setupComplete && !showSetup {
                HomeView(status: status, actions: HomeActions(
                    connect: { controller.connect() },
                    disconnect: controller.disconnect,
                    setUp: { showSetup = true },
                    openSettings: { showSettings = true },
                    openMappings: { showMappings = true },
                    openApplications: { showApplications = true },
                    openApp: { openedApp = $0; showApp = true },
                    resolve: resolve))
            } else {
                OnboardingFlow(controller: controller, finished: { showSetup = false })
                    .transition(.opacity)
            }
        }
        .animation(.entrance, value: controller.setupComplete)
        .fullScreenCover(isPresented: $showSettings, onDismiss: {
            if let band = restartBandSetup {
                restartBandSetup = nil; queuedApp = nil
                controller.setUpBandAgain(for: band)
            } else { showQueuedApp() }
        }) {
            SettingsScreen(controller: controller, setUpBandAgain: { band in
                restartBandSetup = band; showSettings = false
            })
        }
        .fullScreenCover(isPresented: $showMappings, onDismiss: showQueuedApp) {
            MappingsScreen(store: .shared, done: { showMappings = false })
        }
        .fullScreenCover(isPresented: $showApplications, onDismiss: showQueuedApp) {
            ApplicationsScreen(workouts: .shared, done: { showApplications = false })
        }
        .fullScreenCover(isPresented: $showApp) {
            // A widget can swap the app while it is up; the new id starts it from its first screen.
            ApplicationsScreen(workouts: .shared, initialRoute: openedApp.route, done: { showApp = false })
                .id(openedApp)
        }
        .sheet(item: Binding(get: { controller.loginRequest }, set: { if $0 == nil { controller.loginSheetDismissed() } }),
               onDismiss: controller.loginSheetDismissed) { request in
            NavigationStack {
                MetaLoginView(request: request, completed: controller.loginCallback, failed: controller.loginFailed)
                    .navigationTitle("Meta sign-in").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: controller.cancelSignIn) } }
            }
        }
        .alert("Runes", isPresented: Binding(get: { controller.uiError != nil }, set: { if !$0 { controller.uiError = nil } })) {
            Button("OK", role: .cancel) { controller.uiError = nil }
        } message: { Text(controller.uiError ?? "") }
        .onOpenURL { links.open(url: $0) }
        .onChange(of: links.pending, initial: true) { _, app in
            guard let app else { return }
            links.pending = nil
            open(app)
        }
    }

    /// Shows an app a widget asked for, whatever full-screen page was open.
    private func open(_ app: RunesApp) {
        guard controller.setupComplete, !showSetup, !controller.isSigningIn, restartBandSetup == nil else { return }
        if showApp {
            // Already showing an app: change it in place. Leave the same app where it was.
            if openedApp != app { openedApp = app }
        } else if showSettings || showMappings || showApplications {
            // A cover can't come up while another leaves, so wait for its onDismiss.
            queuedApp = app
            showSettings = false; showMappings = false; showApplications = false
        } else {
            openedApp = app; showApp = true
        }
    }

    private func showQueuedApp() {
        guard let app = queuedApp else { return }
        queuedApp = nil
        openedApp = app; showApp = true
    }

    private func resolve(_ action: SessionIssue.Action) {
        if action == .setUpAgain { controller.forgetBand(); showSetup = true } else { controller.perform(action) }
    }
}
