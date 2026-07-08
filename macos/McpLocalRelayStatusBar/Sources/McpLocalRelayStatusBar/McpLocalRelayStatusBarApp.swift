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
    @Published var errorMessage = ""
    @Published var isLoading = false

    private let baseURL = URL(string: "http://127.0.0.1:3764")!
    private let decoder = JSONDecoder()
    private var pollingTask: Task<Void, Never>?

    init() {
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

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

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
                Text(status.compactSummary)
                Text("Uptime \(formatUptime(status.uptimeMs)) · Sessions \(status.sessions)")
            }

            if status.servers.isEmpty {
                Section("Servers") {
                    Text("No upstream MCP servers")
                }
            } else {
                ForEach(status.serverGroups) { group in
                    Section(group.name) {
                        ForEach(group.servers) { server in
                            Menu(server.compactTitle) {
                                if !server.detailText.isEmpty {
                                    Text(server.detailText)
                                }
                                StatusLine(title: "ID", value: server.id)
                                StatusLine(title: "Status", value: server.statusText)
                                StatusLine(title: "Tools", value: String(server.cachedTools))
                                StatusLine(title: "Last refresh", value: formatTime(server.cachedAt))
                                if !server.lastRefreshError.isEmpty {
                                    Text(server.lastRefreshError)
                                }
                                Button("Refresh") {
                                    Task { await model.refreshServer(id: server.id) }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Text("Relay offline")
        }

        if !model.errorMessage.isEmpty {
            Section {
                Text(model.errorMessage)
            }
        }

        Section {
            Button("Refresh Status") {
                Task { await model.refresh() }
            }
            Button("Refresh All MCPs") {
                Task { await model.refreshAllServers() }
            }
            Button("Copy Client Config") {
                Task { await model.copyClientConfig() }
            }
            Button("Open Logs Folder") {
                model.openLogsFolder()
            }
            Button("Restart Relay") {
                Task { await model.restartRelay() }
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

struct StatusLine: View {
    let title: String
    let value: String

    var body: some View {
        Text("\(title): \(value)")
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
