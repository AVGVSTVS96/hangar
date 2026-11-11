import Foundation

enum Demo {
    static let hangar: Hangar? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-demo"), arguments.indices.contains(at + 1) else { return nil }
        let scene = arguments[at + 1]
        let hangar = Hangar(server: nil)
        hangar.reachable = scene != "offline"
        hangar.show(scene == "empty" ? [] : apps)
        if scene == "run" {
            hangar.run = ["com.example.voice", "com.example.keyboard", "com.example.camera", hangarID]
            hangar.jobs = [
                "com.example.voice": .downloading(0.62),
                "com.example.keyboard": .waiting(asked: true),
                "com.example.camera": .queued,
                hangarID: .queued,
            ]
        }
        return hangar
    }()

    private static func app(_ id: String, _ name: String, _ build: Int, phone: Int?, hours: Double, _ notes: String) -> Build {
        Build(
            id: id, name: name, build: build, notes: notes, size: 31_400_000,
            published: .now.addingTimeInterval(-hours * 3600), icon: nil,
            install: URL(string: "itms-services://?action=download-manifest")!, scheme: "\(id)-\(build)", phone: phone)
    }

    private static let apps = [
        app("com.example.voice", "Voice", 726, phone: 712, hours: 0.3, "Calls ring through on the lock screen, and the mute button stays put."),
        app("com.example.keyboard", "Keyboard", 1017, phone: 1009, hours: 2, "Photos in Chats. The skin-tone popup fits on the folded screen."),
        app("com.example.camera", "Camera", 88, phone: nil, hours: 26, "First build."),
        app("com.example.span", "Span", 5903, phone: 5903, hours: 30, ""),
        app(hangarID, "hangar", Hangar.ownBuild + 1, phone: nil, hours: 50, "Shows each download as it goes."),
    ]

    private static let hangarID = Bundle.main.bundleIdentifier ?? "com.shahidy.hangar"
}
