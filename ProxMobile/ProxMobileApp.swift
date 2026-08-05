import SwiftUI

@main
struct ProxMobileApp: App {
    @StateObject private var model = ProxmoxModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
