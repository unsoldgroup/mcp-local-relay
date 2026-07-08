import AppKit
import SwiftUI

@main
struct McpLocalRelayStatusBarApp: App {
    @StateObject private var model = RelayStatusModel()

    var body: some Scene {
        MenuBarExtra {
            RelayMenu(model: model)
                .task {
                    await model.refresh()
                }
        } label: {
            Label(model.menuTitle, systemImage: model.menuIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class RelayStatusModel: ObservableObject {
    @Published var status: RelayStatus?
    @Published var corpusStatus: CorpusCodexStatus?
    @Published var errorMessage = ""
    @Published var corpusErrorMessage = ""
    @Published var isLoading = false

    private let baseURL = URL(string: "http://127.0.0.1:3764")!
    private let corpusBaseURL = URL(string: "http://127.0.0.1:3768")!
    private let decoder = JSONDecoder()
    private var pollingTask: Task<Void, Never>?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    init() {
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.autoPauseForSleep() }
        }
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.autoResumeAfterWake() }
        }
        pollingTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self?.refresh()
            }
        }
    }

    deinit {
        pollingTask?.cancel()
        if let willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(willSleepObserver)
        }
        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
        }
    }

    var menuTitle: String {
        if isLoading { return "Relay" }
        if let status, status.ok { return "Relay" }
        return "Relay"
    }

    var menuIcon: String {
        if status?.ok == true { return "bolt.horizontal.circle.fill" }
        if status != nil { return "exclamationmark.triangle.fill" }
        return "bolt.horizontal.circle"
    }

    var corpusMenuTitle: String {
        guard let corpusStatus else { return "Corpus Codex · Offline" }
        var parts = ["Corpus Codex", corpusStatus.state.capitalized, "\(corpusStatus.done) done"]
        if corpusStatus.failed > 0 { parts.append("\(corpusStatus.failed) failed") }
        if corpusStatus.needsHuman > 0 { parts.append("\(corpusStatus.needsHuman) human") }
        return parts.joined(separator: " · ")
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        await refreshCorpus()
        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "status"))
            try check(response)
            status = try decoder.decode(RelayStatus.self, from: data)
            errorMessage = ""
        } catch {
            status = nil
            errorMessage = error.localizedDescription
        }
    }

    func refreshCorpus() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: corpusBaseURL.appending(path: "status"))
            try check(response)
            corpusStatus = try decoder.decode(CorpusCodexStatus.self, from: data)
            corpusErrorMessage = ""
        } catch {
            corpusStatus = nil
            corpusErrorMessage = error.localizedDescription
        }
    }

    func refreshServer(id: String) async {
        await post(path: "servers/\(id)/refresh")
        await refresh()
    }

    func refreshAllServers() async {
        guard let status else { return }
        for server in status.servers where server.enabled {
            await post(path: "servers/\(server.id)/refresh")
        }
        await refresh()
    }

    func restartRelay() async {
        await post(path: "restart")
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    func corpusStart() async {
        await postCorpus(path: "start", body: [:])
        await refreshCorpus()
    }

    func corpusPause() async {
        await postCorpus(path: "pause", body: [:])
        await refreshCorpus()
    }

    func corpusResume() async {
        await postCorpus(path: "resume", body: [:])
        await refreshCorpus()
    }

    func corpusDrain() async {
        await postCorpus(path: "drain", body: [:])
        await refreshCorpus()
    }

    func corpusStopAfterCurrent() async {
        await postCorpus(path: "stop-after-current", body: [:])
        await refreshCorpus()
    }

    func corpusPushCompleted() async {
        await postCorpus(path: "push-completed", body: [:])
        await refreshCorpus()
    }

    func copyClientConfig() async {
        do {
            let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "client-config"))
            try check(response)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openLogsFolder() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".local/state/mcp-local-relay", directoryHint: .isDirectory)
        NSWorkspace.shared.open(url)
    }

    func openCorpusLedger() {
        NSWorkspace.shared.open(URL(filePath: "/Users/astemarie/code/insurance-corpus/eval/batch/codex-ledger.jsonl"))
    }

    func openCorpusFailures() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:3768/failures")!)
    }

    private func autoPauseForSleep() async {
        guard corpusStatus?.state == "running" else { return }
        await postCorpus(path: "pause", body: ["pausedBy": "status-bar", "reason": "system_sleep"])
        await refreshCorpus()
    }

    private func autoResumeAfterWake() async {
        guard corpusStatus?.pausedBy == "status-bar" else {
            await refreshCorpus()
            return
        }
        await postCorpus(path: "resume", body: ["autoOnly": true])
        await refreshCorpus()
    }

    private func post(path: String) async {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try check(response)
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func postCorpus(path: String, body: [String: Any]) async {
        var request = URLRequest(url: corpusBaseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try check(response)
            corpusErrorMessage = ""
        } catch {
            corpusErrorMessage = error.localizedDescription
        }
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayError.requestFailed
        }
    }
}

struct RelayMenu: View {
    @ObservedObject var model: RelayStatusModel

    var body: some View {
        if let status = model.status {
            Section {
                Label(status.compactSummary, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Label("Uptime \(formatUptime(status.uptimeMs)) · Sessions \(status.sessions)", systemImage: "clock")
            }

            if status.servers.isEmpty {
                Section("Servers") {
                    Text("No upstream MCP servers")
                }
            } else {
                ForEach(status.serverGroups) { group in
                    Section(group.name) {
                        if group.name == "Local Automation" {
                            CorpusCodexMenu(model: model)
                        }
                        ForEach(group.servers) { server in
                            Menu(server.compactTitle) {
                                if !server.detailText.isEmpty {
                                    Text(server.detailText)
                                }
                                StatusLine(title: "ID", value: server.id, systemImage: "number")
                                StatusLine(title: "Status", value: server.statusText, systemImage: server.statusIcon)
                                StatusLine(title: "Tools", value: String(server.cachedTools), systemImage: "wrench.and.screwdriver")
                                StatusLine(title: "Last refresh", value: formatTime(server.cachedAt), systemImage: "clock.arrow.circlepath")
                                if !server.lastRefreshError.isEmpty {
                                    Text(server.lastRefreshError)
                                }
                                Button {
                                    Task { await model.refreshServer(id: server.id) }
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Label("Relay offline", systemImage: "wifi.exclamationmark")
        }

        if !model.errorMessage.isEmpty {
            Section {
                Label(model.errorMessage, systemImage: "exclamationmark.triangle")
            }
        }

        Section {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await model.refreshAllServers() }
            } label: {
                Label("Refresh All MCPs", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                Task { await model.copyClientConfig() }
            } label: {
                Label("Copy Client Config", systemImage: "doc.on.doc")
            }
            Button {
                model.openLogsFolder()
            } label: {
                Label("Open Logs Folder", systemImage: "folder")
            }
            Button {
                Task { await model.restartRelay() }
            } label: {
                Label("Restart Relay", systemImage: "power")
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

struct CorpusCodexMenu: View {
    @ObservedObject var model: RelayStatusModel

    var body: some View {
        Menu {
            if let status = model.corpusStatus {
                Label(status.summary, systemImage: status.systemImage)
                Label(status.detail, systemImage: "gauge.with.dots.needle.50percent")
                if let last = status.lastCompleted, !last.isEmpty {
                    Label("Last: \(last)", systemImage: "checkmark.seal")
                }
                if let heartbeat = status.lastHeartbeatAt, !heartbeat.isEmpty {
                    Label("Heartbeat: \(heartbeat)", systemImage: "waveform.path.ecg")
                }
                Divider()
                Button {
                    Task { await model.corpusStart() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                Button {
                    Task { await model.corpusPause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                Button {
                    Task { await model.corpusResume() }
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                Button {
                    Task { await model.corpusDrain() }
                } label: {
                    Label("Drain After Current", systemImage: "arrow.down.to.line.compact")
                }
                Button {
                    Task { await model.corpusStopAfterCurrent() }
                } label: {
                    Label("Stop After Current", systemImage: "stop.circle")
                }
                Button {
                    Task { await model.corpusPushCompleted() }
                } label: {
                    Label("Push Completed Now", systemImage: "icloud.and.arrow.up")
                }
                Divider()
                Button {
                    model.openCorpusLedger()
                } label: {
                    Label("Open Ledger", systemImage: "list.bullet.rectangle")
                }
                Button {
                    model.openCorpusFailures()
                } label: {
                    Label("Open Failures", systemImage: "exclamationmark.octagon")
                }
            } else {
                Label("Control service offline", systemImage: "wifi.exclamationmark")
                if !model.corpusErrorMessage.isEmpty {
                    Text(model.corpusErrorMessage)
                }
            }
        } label: {
            Label(model.corpusMenuTitle, systemImage: model.corpusStatus?.systemImage ?? "doc.text.magnifyingglass")
        }
    }
}

struct StatusLine: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        Label("\(title): \(value)", systemImage: systemImage)
    }
}

struct RelayStatus: Decodable {
    let ok: Bool
    let uptimeMs: Int
    let sessions: Int
    let servers: [RelayServerStatus]

    var healthyServerCount: Int {
        servers.filter(\.isHealthy).count
    }

    var totalTools: Int {
        servers.reduce(0) { $0 + $1.cachedTools }
    }

    var compactSummary: String {
        let state = ok ? "Running" : "Needs attention"
        return "\(state): \(healthyServerCount)/\(servers.count) MCPs · \(totalTools) tools"
    }

    var serverGroups: [RelayServerGroup] {
        let sortedServers = servers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sortedServers) { $0.categoryText }
        return grouped
            .map { RelayServerGroup(name: $0.key, servers: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct RelayServerGroup: Identifiable {
    let name: String
    let servers: [RelayServerStatus]

    var id: String { name }
}

struct RelayServerStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let enabled: Bool
    let connected: Bool
    let cachedTools: Int
    let cachedAt: Int
    let lastRefreshError: String

    var isHealthy: Bool {
        enabled && lastRefreshError.isEmpty
    }

    var statusText: String {
        if !enabled { return "Disabled" }
        if !lastRefreshError.isEmpty { return "Error" }
        if connected { return "Connected" }
        return "Ready"
    }

    var statusIcon: String {
        if !enabled { return "pause.circle" }
        if !lastRefreshError.isEmpty { return "exclamationmark.triangle" }
        if connected { return "checkmark.circle" }
        return "circle"
    }

    var categoryText: String {
        let value = (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Other" : value
    }

    var detailText: String {
        (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var compactTitle: String {
        "\(name) · \(statusText) · \(cachedTools)"
    }
}

struct CorpusCodexStatus: Decodable {
    let ok: Bool
    let state: String
    let active: Int
    let workers: Int?
    let dispatched: Int
    let total: Int?
    let done: Int
    let failed: Int
    let needsHuman: Int
    let pending: Int?
    let lastCompleted: String?
    let lastStatus: String?
    let lastHeartbeatAt: String?
    let etaHours: Double?
    let pausedBy: String?

    var summary: String {
        var parts = ["\(state.capitalized)", "\(done) done"]
        if failed > 0 { parts.append("\(failed) failed") }
        if needsHuman > 0 { parts.append("\(needsHuman) needs human") }
        if let etaHours { parts.append("ETA \(formatEta(etaHours))") }
        return parts.joined(separator: " · ")
    }

    var detail: String {
        let workerText = workers.map { "\(active)/\($0)" } ?? "\(active)"
        let pendingText = pending.map { "\($0) pending" } ?? "pending unknown"
        let pauseText = pausedBy.map { " · paused by \($0)" } ?? ""
        return "Active \(workerText) · \(dispatched) dispatched · \(pendingText)\(pauseText)"
    }

    var systemImage: String {
        switch state.lowercased() {
        case "running": return "play.circle.fill"
        case "paused": return "pause.circle.fill"
        case "draining": return "arrow.down.circle.fill"
        case "stopping": return "stop.circle.fill"
        case "complete": return "checkmark.circle.fill"
        case "attention": return "exclamationmark.triangle.fill"
        default: return ok ? "doc.text.magnifyingglass" : "exclamationmark.triangle.fill"
        }
    }
}

private func formatEta(_ hours: Double) -> String {
    if hours >= 48 { return String(format: "%.1fd", hours / 24) }
    if hours >= 1 { return String(format: "%.1fh", hours) }
    return "\(Int(hours * 60))m"
}

enum RelayError: Error {
    case requestFailed
}

private func formatUptime(_ ms: Int) -> String {
    let seconds = max(0, ms / 1000)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func formatTime(_ epochMs: Int) -> String {
    guard epochMs > 0 else { return "Never" }
    let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
    return date.formatted(date: .omitted, time: .shortened)
}
