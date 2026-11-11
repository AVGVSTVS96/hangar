import SwiftUI
import UIKit

struct Build: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let build: Int
    let notes: String
    let size: Int
    let published: Date
    let icon: URL?
    let install: URL
    let scheme: String
    let phone: Int?
    let downloaded: Int?

    var isHangar: Bool { id == Bundle.main.bundleIdentifier }
    var installed: Int? { isHangar ? Hangar.ownBuild : phone }
    var isCurrent: Bool { (installed ?? 0) >= build }
    var isDownloaded: Bool { !isCurrent && (downloaded ?? 0) >= build }
    var launch: URL? { URL(string: "\(scheme)://") }
}

struct Progress: Decodable {
    enum Step: String, Decodable { case asked, downloading, downloaded, stopped }

    let id: String
    let build: Int
    let step: Step
    let sent: Int
    let size: Int
}

enum Job: Equatable {
    case queued
    case waiting(asked: Bool)
    case downloading(Double)
    case installing
    case done
    case failed(String)

    var fraction: Double {
        switch self {
        case .queued, .waiting, .failed: 0
        case .downloading(let fraction): fraction
        case .installing, .done: 1
        }
    }

    var isActive: Bool {
        switch self {
        case .done, .failed: false
        default: true
        }
    }
}

@Observable
final class Hangar {
    static let ownBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

    var apps: [Build] = []
    var jobs: [String: Job] = [:]
    var run: [String] = []
    var reachable = true
    var loaded = false

    private let server: URL?
    private var queue: [String] = []
    private(set) var current: String?
    private var reopen: Set<String> = []
    private var requested: String?
    private var stream: Task<Void, Never>?
    private var heard = Date.distantPast

    init(server: URL? = (Bundle.main.object(forInfoDictionaryKey: "HangarURL") as? String).flatMap(URL.init)) {
        self.server = server
    }

    var updates: [Build] { apps.filter { !$0.isCurrent && !$0.isDownloaded } }
    var shown: [Build] { apps.filter { !$0.isHangar || !$0.isCurrent || jobs[$0.id] != nil } }
    var running: Bool { run.contains { jobs[$0]?.isActive == true } }
    var focus: String? { current ?? run.first { jobs[$0]?.isActive == true } }
    var finished: Int { run.count { jobs[$0]?.isActive != true } }
    var fraction: Double { run.isEmpty ? 0 : run.map { jobs[$0]?.fraction ?? 1 }.reduce(0, +) / Double(run.count) }

    func connect() {
        guard let server, Date.now.timeIntervalSince(heard) > 25 else { return }
        stream?.cancel()
        stream = Task {
            var failures = 0
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: server.appending(path: "events"))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    reachable = true
                    failures = 0
                    var event = ""
                    for try await line in bytes.lines {
                        heard = .now
                        if line.hasPrefix("event: ") {
                            event = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            receive(event, Data(line.dropFirst(6).utf8))
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    reachable = failures < 2
                    heard = .distantPast
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static let decoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        return decoder
    }()

    private func receive(_ event: String, _ data: Data) {
        if event == "apps", let apps = try? Self.decoder.decode([Build].self, from: data) {
            show(apps)
        } else if event == "install", let progress = try? Self.decoder.decode(Progress.self, from: data) {
            receive(progress)
        }
    }

    func show(_ apps: [Build]) {
        let order = self.apps.map(\.id)
        if running, apps.allSatisfy({ order.contains($0.id) }) {
            self.apps = apps.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        } else {
            let rank = { (app: Build) in app.isHangar ? 2 : app.isCurrent ? 1 : 0 }
            self.apps = apps.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
        }
        loaded = true
        for app in apps where jobs[app.id] == .installing && !reopen.contains(app.id) && (app.isCurrent || app.isDownloaded) {
            jobs[app.id] = nil
        }
        startRequested()
    }

    private func receive(_ progress: Progress) {
        let id = progress.id
        switch progress.step {
        case .asked:
            if case .waiting = jobs[id] { jobs[id] = .waiting(asked: true) }
        case .downloading:
            jobs[id] = .downloading(Double(progress.sent) / Double(max(progress.size, 1)))
            moveOn(from: id)
        case .downloaded:
            jobs[id] = .installing
            Task { await finish(id) }
            next()
        case .stopped:
            let percent = (Double(progress.sent) / Double(max(progress.size, 1))).formatted(.percent.precision(.fractionLength(0)))
            jobs[id] = .failed("Stopped at \(percent)")
            reopen.remove(id)
            moveOn(from: id)
        }
    }

    private func report(_ event: String, _ app: Build, _ detail: String? = nil) {
        guard let server else { return }
        var request = URLRequest(url: server.appending(path: "log"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["event": event, "id": app.id, "build": app.build]
        body["detail"] = detail
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { _ = try? await URLSession.shared.data(for: request) }
    }

    func install(_ targets: [Build]) {
        let fresh = targets.filter { jobs[$0.id]?.isActive != true }
        guard !fresh.isEmpty else { return }
        if fresh.count == 1, !running, !fresh[0].isHangar { reopen.insert(fresh[0].id) }
        if !running { run = [] }
        for app in fresh {
            jobs[app.id] = .queued
            queue.append(app.id)
            run.append(app.id)
        }
        queue.sort { !isHangar($0) && isHangar($1) }
        next()
    }

    private func isHangar(_ id: String) -> Bool { id == Bundle.main.bundleIdentifier }

    private func app(_ id: String) -> Build? { apps.first { $0.id == id } }

    private func next() {
        guard current == nil, let id = queue.first else { return }
        let downloading = jobs.contains { if case .downloading = $0.value { true } else { false } }
        if isHangar(id) && downloading { return }
        queue.removeFirst()
        guard let app = app(id) else { return next() }
        current = id
        jobs[id] = .waiting(asked: false)
        report("opening install link", app, app.isHangar ? "hangar closes to update itself" : nil)
        Task {
            let opened = await UIApplication.shared.open(app.install)
            if !opened { report("iOS returned false opening the install link", app) }
        }
        Task {
            try? await Task.sleep(for: .seconds(45))
            if jobs[id] == .waiting(asked: false) { giveUp(on: id, after: "45s") }
        }
    }

    private func moveOn(from id: String) {
        guard current == id else { return }
        current = nil
        next()
    }

    func becameActive() {
        connect()
        guard let id = current else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            giveUp(on: id, after: "the alert closed")
        }
    }

    private func giveUp(on id: String, after reason: String) {
        guard current == id, case .waiting(let asked) = jobs[id], let app = app(id) else { return }
        reopen.remove(id)
        if asked {
            jobs[id] = nil
            run.removeAll { $0 == id }
            report("no download after the Install alert (\(reason)): Cancel was tapped", app)
        } else {
            jobs[id] = .failed("Couldn't reach hangar")
            report("iOS never asked for the manifest (\(reason))", app)
        }
        moveOn(from: id)
    }

    private func finish(_ id: String) async {
        guard reopen.contains(id), let app = app(id), let launch = app.launch else { return }
        defer { reopen.remove(id) }
        var waited = 0
        while waited < 120 {
            if UIApplication.shared.applicationState == .active {
                if await UIApplication.shared.open(launch) {
                    done(id)
                    report("opened", app)
                    return
                }
                waited += 1
            }
            try? await Task.sleep(for: .seconds(1))
        }
        jobs[id] = .failed("iOS didn't install \(app.build)")
        report("the new build never answered its URL scheme in 2 minutes: iOS didn't install it", app)
    }

    func open(_ app: Build) {
        guard let launch = app.launch else { return }
        Task {
            if await UIApplication.shared.open(launch) {
                report("opened", app)
            } else {
                jobs[app.id] = .failed(app.isDownloaded ? "iOS didn't install \(app.build)" : "\(app.build) isn't on this phone")
                report("open failed: the build isn't installed", app)
            }
        }
    }

    private func done(_ id: String) {
        jobs[id] = .done
        Task {
            try? await Task.sleep(for: .seconds(4))
            if jobs[id] == .done { jobs[id] = nil }
        }
    }

    func handle(_ url: URL) {
        guard url.scheme == "hangar", url.host() == "update", let id = url.pathComponents.dropFirst().first else { return }
        requested = id
        startRequested()
    }

    private func startRequested() {
        guard let id = requested, let app = app(id) else { return }
        requested = nil
        reopen.insert(id)
        report("update asked for by the app", app)
        install([app])
    }
}
