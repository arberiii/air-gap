import SwiftUI

@main
struct AirGapApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(state)
        } label: {
            if let title = state.menuTitle {
                Label(title, systemImage: state.justBlocked ? "nosign" : state.isLocked ? "lock.fill" : "scope")
            } else if state.justBlocked {
                Image(systemName: "nosign")
            } else if state.isLocked {
                Image(systemName: "lock.fill")
            } else if state.review != nil {
                Image(systemName: "checkmark.bubble")
            } else {
                Image(systemName: "hourglass")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
