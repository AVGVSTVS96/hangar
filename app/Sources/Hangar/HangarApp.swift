import SwiftUI

@main
struct HangarApp: App {
    @State private var hangar = Demo.hangar ?? Hangar()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            AppsView(caption: Demo.hangar == nil ? nil : "Made-up apps, for a simulator screenshot")
                .environment(hangar)
                .onOpenURL { hangar.handle($0) }
                .onChange(of: phase, initial: true) { _, phase in
                    if phase == .active && Demo.hangar == nil { hangar.becameActive() }
                }
        }
    }
}
