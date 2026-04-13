import SwiftUI

@main
struct ply2splatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {} // Removes empty "New" menu item
        }
    }
}
