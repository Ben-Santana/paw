import SwiftUI

/// Binds the live controller to the value-driven screens.
struct RootView: View {
    @ObservedObject var controller: SessionController
    @State private var showSettings = false
    @State private var showMappings = false
    @State private var showApplications = false
    @State private var openedApp: RunesApp?
    @State private var showSetup = false

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
                    openApp: { openedApp = $0 },
                    resolve: resolve))
            } else {
                OnboardingFlow(controller: controller, finished: { showSetup = false })
                    .transition(.opacity)
            }
        }
        .animation(.entrance, value: controller.setupComplete)
        .fullScreenCover(isPresented: $showSettings) {
            SettingsScreen(controller: controller)
        }
        .fullScreenCover(isPresented: $showMappings) {
            MappingsScreen(store: .shared, done: { showMappings = false })
        }
        .fullScreenCover(isPresented: $showApplications) {
            ApplicationsScreen(workouts: .shared, done: { showApplications = false })
        }
        .fullScreenCover(item: $openedApp) { app in
            ApplicationsScreen(workouts: .shared, initialRoute: app.route, done: { openedApp = nil })
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
    }

    private func resolve(_ action: SessionIssue.Action) {
        if action == .setUpAgain { controller.forgetBand(); showSetup = true } else { controller.perform(action) }
    }
}
