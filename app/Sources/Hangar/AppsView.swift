import SwiftUI

struct AppsView: View {
    @Environment(Hangar.self) private var hangar
    var caption: String?

    @State private var width: CGFloat = 0
    private var margin: CGFloat { width >= 600 ? 20 : 16 }
    private var columns: Int { width - 2 * margin >= 732 ? 2 : 1 }
    private var columnWidth: CGFloat { (width - 2 * margin - CGFloat(columns - 1) * 12) / CGFloat(columns) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                        if let caption {
                            Text(caption).font(.footnote).foregroundStyle(.secondary)
                        }
                        if !hangar.reachable { Offline() }
                        Section {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(0..<columns, id: \.self) { column in
                                    VStack(spacing: 12) {
                                        ForEach(hangar.shown.enumerated().filter { $0.offset % columns == column }.map(\.element)) {
                                            AppCard(app: $0).id($0.id)
                                        }
                                    }
                                }
                            }
                        } header: {
                            UpdateAll()
                                .frame(maxWidth: columns > 1 ? columnWidth : .infinity)
                                .padding(.top, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.systemGroupedBackground))
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.bottom, 24)
                    .animation(.snappy, value: hangar.reachable)
                    .animation(.snappy, value: hangar.shown.map(\.id))
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
                .onChange(of: hangar.focus, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { scroller.scrollTo(id) }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("hangar")
            .navigationSubtitle(summary)
            .toolbarTitleDisplayMode(.inlineLarge)
            .overlay {
                if hangar.loaded && hangar.apps.isEmpty {
                    ContentUnavailableView(
                        "No apps yet", systemImage: "square.and.arrow.down",
                        description: Text("An app shows up here once a build of it is put on hangar."))
                }
            }
        }
    }

    private var summary: String {
        if !hangar.loaded { return hangar.reachable ? "Connecting" : "Offline" }
        if hangar.apps.isEmpty { return "Nothing to install" }
        if hangar.running {
            let total = hangar.run.count
            return total == 1 ? "Updating" : "Updating \(min(hangar.finished + 1, total)) of \(total)"
        }
        let count = hangar.updates.count
        return count == 0 ? "Everything is up to date" : "\(count) new \(count == 1 ? "build" : "builds")"
    }
}

private struct Offline: View {
    var body: some View {
        Label("Can't reach hangar. Is Tailscale on?", systemImage: "wifi.slash")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
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
                        Text(app.published, format: .relative(presentation: .named, unitsStyle: .narrow))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
        guard let installed = app.installed else { return "Build \(app.build) · not installed" }
        return installed >= app.build ? "Build \(app.build)" : "\(installed) → \(app.build)"
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
            case .failed: pill("Retry") { hangar.install([app]) }.disabled(!hangar.reachable)
            case nil:
                if !app.isCurrent {
                    pill(app.installed == nil ? "Install" : "Update") { hangar.install([app]) }.disabled(!hangar.reachable)
                } else if !app.isHangar {
                    pill("Open") { hangar.open(app) }.tint(.secondary)
                }
            }
        }
        .frame(minWidth: 32, minHeight: 32, alignment: .trailing)
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
        if hangar.running || !hangar.updates.isEmpty {
            Button {
                hangar.install(hangar.updates)
            } label: {
                Text(hangar.running ? step : label)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(hangar.running ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    .contentTransition(.opacity)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background { fill }
                    .clipShape(.capsule)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!hangar.running)
            .disabled(!hangar.running && !hangar.reachable)
            .sensoryFeedback(.impact(weight: .medium), trigger: hangar.running) { _, running in running }
            .animation(.snappy, value: hangar.running)
            .animation(.snappy, value: hangar.fraction)
            .transition(.opacity)
        }
    }

    private var fill: some View {
        ZStack(alignment: .leading) {
            if hangar.running {
                Color(.secondarySystemGroupedBackground)
                GeometryReader { size in
                    Rectangle().fill(.tint.opacity(0.4)).frame(width: size.size.width * hangar.fraction)
                }
            } else {
                Rectangle().fill(.tint)
            }
        }
    }

    private var label: String {
        let updates = hangar.updates
        let verb = updates.contains { $0.installed != nil } ? "Update" : "Install"
        return updates.count == 1 ? "\(verb) \(updates[0].name)" : "\(verb) all \(updates.count)"
    }

    private var step: String {
        guard let id = hangar.focus, let app = hangar.apps.first(where: { $0.id == id }) else { return "Updating" }
        switch hangar.jobs[id] {
        case .queued: return app.isHangar ? "hangar updates itself last" : "\(app.name) is up next"
        case .waiting(asked: false): return "Asking iOS to install \(app.name)"
        case .waiting(asked: true): return "Tap Install for \(app.name)"
        case .downloading: return "Downloading \(app.name)"
        case .installing: return "Installing \(app.name)"
        case .done, .failed, nil: return "Updating"
        }
    }
}
