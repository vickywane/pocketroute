import FirebaseAppCheck
import FirebaseCore
import SwiftUI

@main
struct PockerRouterApp: App {
    init() {
        // Firebase is optional for the local demo. Configure it only after the
        // developer adds their app-specific GoogleService-Info.plist.
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
