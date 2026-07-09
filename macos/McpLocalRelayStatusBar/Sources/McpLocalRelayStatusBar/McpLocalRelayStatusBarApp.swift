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
    @Published var menuStatus: RelayMenuStatus?
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

        do {
            async let statusResult = fetchStatus()
            async let menuResult = fetchMenu()
            status = try await statusResult
            menuStatus = try await menuResult
            errorMessage = ""
        } catch {
            status = nil
            menuStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    private func fetchStatus() async throws -> RelayStatus {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "status"))
        try check(response)
        return try decoder.decode(RelayStatus.self, from: data)
    }

    private func fetchMenu() async throws -> RelayMenuStatus {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: "menu"))
        try check(response)
        return try decoder.decode(RelayMenuStatus.self, from: data)
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
        await refresh()
    }

    func refreshAllServers() async {
        await refresh()
    }

    func runMenuAction(serverId: String, actionId: String, confirm: Bool) async {
        var request = URLRequest(url: baseURL.appending(path: "servers/\(serverId)/menu/actions/\(actionId)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["confirm": confirm])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try check(response)
            errorMessage = ""
        } catch {
            errorMessage = error.localizedDescription
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
                        ForEach(group.servers) { server in
                            ServerMenu(model: model, server: server, menu: model.menuStatus?.server(id: server.id))
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

struct ServerMenu: View {
    @ObservedObject var model: RelayStatusModel
    let server: RelayServerStatus
    let menu: RelayMenuServer?

    var body: some View {
        Menu {
            if let menu {
                Label(menu.summary, systemImage: menu.systemImage)
                ForEach(menu.detail.prefix(8), id: \.self) { line in
                    Text(line)
                }
                Divider()
                if menu.actions.isEmpty {
                    Text("No quick actions")
                } else {
                    ForEach(menu.actions) { action in
                        if let view = action.view {
                            Menu {
                                CompactRelayView(view: view)
                            } label: {
                                Label(action.label, systemImage: action.systemImage ?? "tablecells")
                            }
                        } else {
                            Button {
                                if let url = action.url, let parsed = URL(string: url) {
                                    NSWorkspace.shared.open(parsed)
                                } else {
                                    Task {
                                        await model.runMenuAction(
                                            serverId: server.id,
                                            actionId: action.id,
                                            confirm: action.confirm
                                        )
                                    }
                                }
                            } label: {
                                Label(action.label, systemImage: action.systemImage ?? "bolt")
                            }
                        }
                    }
                }
            } else {
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
            }
            Divider()
            Button {
                Task { await model.refreshServer(id: server.id) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Label(menu?.compactTitle ?? server.compactTitle, systemImage: menu?.systemImage ?? server.statusIcon)
        }
    }
}

struct CompactRelayView: View {
    let view: RelayActionView

    var body: some View {
        if !view.summary.isEmpty {
            Label(view.summary, systemImage: "chart.bar.doc.horizontal")
        } else {
            Label(view.title, systemImage: "tablecells")
        }
        if let refreshSeconds = view.refreshSeconds {
            Text("Refreshes every \(refreshSeconds)s")
        }
        Divider()
        if view.rows.isEmpty {
            Text("No rows")
        } else {
            ForEach(Array(view.rows.prefix(8).enumerated()), id: \.offset) { _, row in
                Label(row.display(columns: view.columns), systemImage: row.statusIcon)
            }
        }
        if !view.footerActions.isEmpty {
            Divider()
            ForEach(view.footerActions) { action in
                Button {
                    if let parsed = URL(string: action.url) {
                        NSWorkspace.shared.open(parsed)
                    }
                } label: {
                    Label(action.label, systemImage: action.systemImage ?? "arrow.up.forward.app")
                }
            }
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

struct RelayMenuStatus: Decodable {
    let ok: Bool
    let servers: [RelayMenuServer]

    func server(id: String) -> RelayMenuServer? {
        servers.first { $0.id == id }
    }
}

struct RelayMenuServer: Decodable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let state: String
    let detail: [String]
    let actions: [RelayMenuAction]
    let cachedAt: Int?
    let lastError: String?

    var compactTitle: String {
        "\(title) · \(summary)"
    }

    var systemImage: String {
        switch state.lowercased() {
        case "ready", "complete": return "checkmark.circle"
        case "running", "syncing": return "arrow.triangle.2.circlepath"
        case "paused": return "pause.circle"
        case "stale", "attention", "error": return "exclamationmark.triangle"
        case "empty": return "tray"
        default: return "circle"
        }
    }
}

struct RelayMenuAction: Decodable, Identifiable {
    let id: String
    let label: String
    let systemImage: String?
    let confirm: Bool
    let tool: String?
    let url: String?
    let view: RelayActionView?

    private enum CodingKeys: String, CodingKey {
        case id, label, systemImage, confirm, tool, url, view
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        systemImage = try c.decodeIfPresent(String.self, forKey: .systemImage)
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        view = try c.decodeIfPresent(RelayActionView.self, forKey: .view)
    }
}

struct RelayActionView: Decodable {
    let type: String
    let title: String
    let summary: String
    let refreshSeconds: Int?
    let density: String?
    let columns: [RelayViewColumn]
    let rows: [RelayViewRow]
    let footerActions: [RelayViewFooterAction]

    private enum CodingKeys: String, CodingKey {
        case type, title, summary, refreshSeconds, density, columns, rows, footerActions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds)
        density = try c.decodeIfPresent(String.self, forKey: .density)
        columns = try c.decodeIfPresent([RelayViewColumn].self, forKey: .columns) ?? []
        rows = try c.decodeIfPresent([RelayViewRow].self, forKey: .rows) ?? []
        footerActions = try c.decodeIfPresent([RelayViewFooterAction].self, forKey: .footerActions) ?? []
    }
}

struct RelayViewColumn: Decodable {
    let id: String
    let label: String
    let kind: String?
}

struct RelayViewRow: Decodable {
    let values: [String: String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        var next: [String: String] = [:]
        for key in c.allKeys {
            if let string = try? c.decode(String.self, forKey: key) {
                next[key.stringValue] = string
            } else if let int = try? c.decode(Int.self, forKey: key) {
                next[key.stringValue] = String(int)
            } else if let double = try? c.decode(Double.self, forKey: key) {
                next[key.stringValue] = String(double)
            } else if let bool = try? c.decode(Bool.self, forKey: key) {
                next[key.stringValue] = bool ? "true" : "false"
            }
        }
        values = next
    }

    var statusIcon: String {
        switch values["status"]?.lowercased() {
        case "success": return "checkmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "error": return "xmark.octagon.fill"
        case "paused": return "pause.circle.fill"
        default: return "circle.fill"
        }
    }

    func display(columns: [RelayViewColumn]) -> String {
        let visibleColumns = columns.filter { $0.kind != "status" }
        let ordered = visibleColumns.isEmpty ? values.keys.sorted() : visibleColumns.map(\.id)
        return ordered
            .compactMap { values[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct RelayViewFooterAction: Decodable, Identifiable {
    let id: String
    let label: String
    let systemImage: String?
    let url: String
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
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
