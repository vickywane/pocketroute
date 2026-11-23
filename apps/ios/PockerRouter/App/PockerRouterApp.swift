import FirebaseAppCheck
import FirebaseCore
import SwiftUI

@main
struct PockerRouterApp: App {
    init() {
        // Firebase is optional: configure it only when the app-specific
        // GoogleService-Info.plist has been added (it is gitignored).
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #endif
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            JourneyHomeView()
        }
    }
}

