import Foundation

enum Demo {
    static let hangar: Hangar? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: "-demo"), arguments.indices.contains(at + 1) else { return nil }
        let scene = arguments[at + 1]
        let hangar = Hangar(server: nil)
        hangar.reachable = scene != "offline"
        switch scene {
        case "connecting": break
        case "empty": hangar.show([])
        case "current": hangar.show(apps.filter { !$0.isHangar }.map { $0.with(phone: $0.build) })
        case "states": hangar.show(apps.map { $0.name == "Span" ? $0.with(build: 5904, downloaded: 5904) : $0 })
        default: hangar.show(apps)
        }
        let voice = "com.example.voice", keyboard = "com.example.keyboard", camera = "com.example.camera"
        if scene == "run" {
            hangar.run = [keyboard, voice, camera, hangarID]
            hangar.jobs = [voice: .downloading(0.62), keyboard: .waiting(asked: true), camera: .queued, hangarID: .queued]
        } else if scene == "late" {
            hangar.run = [hangarID, camera, keyboard, voice]
            hangar.jobs = [camera: .done, keyboard: .done, voice: .installing, hangarID: .waiting(asked: true)]
        } else if scene == "states" {
            hangar.run = [voice, keyboard, camera, hangarID]
            hangar.jobs = [
                voice: .done, keyboard: .failed("Stopped at 41%"), camera: .installing, hangarID: .waiting(asked: false),
            ]
        }
        return hangar
    }()

    private static func app(_ id: String, _ name: String, _ build: Int, phone: Int?, hours: Double, _ notes: String) -> Build {
        Build(
            id: id, name: name, build: build, notes: notes, size: 31_400_000,
            published: .now.addingTimeInterval(-hours * 3600), icon: nil,
            install: URL(string: "itms-services://?action=download-manifest")!, scheme: "\(id)-\(build)", phone: phone,
            downloaded: nil)
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

private extension Build {
    func with(build: Int? = nil, phone: Int? = nil, downloaded: Int? = nil) -> Build {
        let build = build ?? self.build
        return Build(
            id: id, name: name, build: build, notes: notes, size: size, published: published, icon: icon,
            install: install, scheme: "\(id)-\(build)", phone: phone ?? self.phone, downloaded: downloaded ?? self.downloaded)
    }
}
