// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hangar",
    platforms: [.iOS(.v26)],
    products: [.library(name: "Hangar", targets: ["Hangar"])],
    targets: [
        .target(
            name: "Hangar",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .treatAllWarnings(as: .error),
            ]
        )
    ]
)
