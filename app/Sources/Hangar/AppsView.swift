import SwiftUI

struct AppsView: View {
    @Environment(Hangar.self) private var hangar
    var caption: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let caption {
                        Text(caption).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !hangar.reachable { Offline() }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                        ForEach(hangar.apps) { AppCard(app: $0) }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
                .animation(.snappy, value: hangar.reachable)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("hangar")
            .navigationSubtitle(summary)
            .overlay {
                if hangar.loaded && hangar.apps.isEmpty {
                    ContentUnavailableView(
                        "No apps yet", systemImage: "square.and.arrow.down",
                        description: Text("An app shows up here once a build of it is put on hangar."))
                }
            }
            .safeAreaInset(edge: .bottom) { UpdateAll() }
        }
    }

    private var summary: String {
        let count = hangar.updates.count
        if !hangar.loaded { return hangar.reachable ? "Connecting" : "" }
        return count == 0 ? "Everything is up to date" : "\(count) new \(count == 1 ? "build" : "builds")"
    }
}

private struct Offline: View {
    var body: some View {
        Label("Can't reach hangar's server. Is Tailscale on?", systemImage: "wifi.slash")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct AppCard: View {
    @Environment(Hangar.self) private var hangar
    let app: Build

    private var job: Job? { hangar.jobs[app.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                AppIcon(app: app, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(app.name).font(.headline)
                        Text(app.published, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .lineLimit(1)
                    Text(status)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.numericText())
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Action(app: app, job: job)
            }
            if !app.notes.isEmpty {
                Text(app.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
        .animation(.snappy, value: job)
        .sensoryFeedback(.success, trigger: job == .done) { _, done in done }
        .sensoryFeedback(.error, trigger: isFailed) { _, failed in failed }
    }

    private var isFailed: Bool {
        if case .failed = job { true } else { false }
    }

    private var status: String {
        let megabytes = { (bytes: Double) in (bytes / 1e6).formatted(.number.precision(.fractionLength(0))) }
        switch job {
        case .queued: return app.isHangar ? "Updates itself last" : "Up next"
        case .waiting(asked: false): return "Opening the install alert"
        case .waiting(asked: true): return app.isHangar ? "Closes to update itself" : "Tap Install on the alert"
        case .downloading(let fraction):
            return "Downloading \(megabytes(fraction * Double(app.size))) of \(megabytes(Double(app.size))) MB"
        case .installing: return "Installing build \(app.build)"
        case .done: return "Updated to build \(app.build)"
        case .failed(let reason): return reason
        case nil: break
        }
        guard let installed = app.installed else { return "Build \(app.build)" }
        return installed >= app.build ? "\(app.build) · up to date" : "\(installed) → \(app.build)"
    }
}

private struct Action: View {
    @Environment(Hangar.self) private var hangar
    let app: Build
    let job: Job?

    var body: some View {
        Group {
            switch job {
            case .queued: Ring(fraction: 0)
            case .waiting, .installing: Ring(fraction: nil)
            case .downloading(let fraction): Ring(fraction: fraction)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            case .failed: pill("Retry") { hangar.install([app]) }
            case nil:
                if !app.isCurrent {
                    pill(app.installed == nil ? "Install" : "Update") { hangar.install([app]) }
                } else if !app.isHangar {
                    pill("Open") { hangar.open(app) }
                }
            }
        }
        .frame(minWidth: 32, minHeight: 32)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .sensoryFeedback(.impact(weight: .light), trigger: job)
    }
}

private struct Ring: View {
    let fraction: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction ?? 0.28)
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .animation(.snappy, value: fraction)
        }
        .frame(width: 28, height: 28)
        .onAppear { spin = fraction == nil }
        .onChange(of: fraction == nil) { _, indeterminate in spin = indeterminate }
        .animation(fraction == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spin)
    }
}

struct AppIcon: View {
    let app: Build
    let size: CGFloat

    var body: some View {
        AsyncImage(url: app.icon) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Tile(name: app.name, seed: app.id)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.225))
        .overlay { RoundedRectangle(cornerRadius: size * 0.225).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

private struct Tile: View {
    let name: String
    let seed: String

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 360) / 360
        LinearGradient(
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.95), Color(hue: hue, saturation: 0.75, brightness: 0.7)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay {
            Text(name.prefix(1).uppercased()).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
    }
}

private struct UpdateAll: View {
    @Environment(Hangar.self) private var hangar

    var body: some View {
        Group {
            if hangar.running {
                progress
            } else if !hangar.updates.isEmpty {
                Button {
                    hangar.install(hangar.updates)
                } label: {
                    Text(label).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .sensoryFeedback(.impact(weight: .medium), trigger: hangar.running)
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(.snappy, value: hangar.running)
    }

    private var label: String {
        let count = hangar.updates.count
        let verb = hangar.updates.allSatisfy { $0.installed == nil } ? "Install" : "Update"
        return count == 1 ? "\(verb) \(hangar.updates[0].name)" : "\(verb) \(count) apps"
    }

    private var progress: some View {
        let jobs = hangar.run.compactMap { hangar.jobs[$0] }
        let finished = jobs.filter { !$0.isActive }.count
        let fraction = jobs.isEmpty ? 0 : jobs.map(\.fraction).reduce(0, +) / Double(jobs.count)
        let total = hangar.run.count
        return VStack(spacing: 8) {
            Text(total == 1 ? "Updating" : "Updating \(min(finished + 1, total)) of \(total)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            ProgressView(value: fraction).tint(.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy, value: fraction)
    }
}
