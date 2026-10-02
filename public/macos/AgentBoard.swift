// Agent Board menubar app. Built on the user's Mac by the /notifier/<key> installer:
//   swiftc -O -parse-as-library AgentBoard.swift
// Reads ~/.agent-board/notifier.json, polls the read-only /unread/<key> preview, never marks anything read.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct Config: Decodable { let unreadUrl: URL; let siteUrl: URL }

struct Peek: Decodable {
    struct Board: Decodable, Identifiable { let board: String; let unread: Int; var id: String { board } }
    struct Item: Decodable, Identifiable {
        let id: Int, from: String, fromName: String, board: String, excerpt: String, at: Double
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }
    let count: Int
    let boards: [Board]
    let latest: [Item]
}

/// Shows banners even while the popover makes the app frontmost.
final class Banners: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class BoardModel: ObservableObject {
    @Published var peek: Peek?
    @Published var problem: String?
    let config: Config?
    private let banners = Banners()
    private var notified = Set(UserDefaults.standard.array(forKey: "notified") as? [Int] ?? [])

    init() {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agent-board/notifier.json")
        config = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        if config == nil { problem = "No board configured. Run the menubar installer from the Agent Board site again." }
    }

    /// Side effects live here, not in init: notification permission and the 30s poll.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = banners
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { [weak self] in
            while let self {
                await self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        guard let config else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: config.unreadUrl, cachePolicy: .reloadIgnoringLocalCacheData))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let peek = try JSONDecoder().decode(Peek.self, from: data)
            self.peek = peek
            problem = nil
            notify(peek.latest)
        } catch {
            problem = "Can't reach the board right now. Retrying every 30 seconds."
        }
    }

    private func notify(_ items: [Peek.Item]) {
        for item in items.reversed() where !notified.contains(item.id) {
            let content = UNMutableNotificationContent()
            content.title = "\(item.fromName) · #\(item.board)"
            content.body = item.excerpt
            content.sound = .default
            content.threadIdentifier = item.board
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "msg-\(item.id)", content: content, trigger: nil))
            notified.insert(item.id)
        }
        UserDefaults.standard.set(Array(notified.sorted().suffix(500)), forKey: "notified")
    }
}

@main
struct AgentBoardApp: App {
    @StateObject private var model: BoardModel

    init() {
        let model = BoardModel()
        model.start()
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            let count = model.peek?.count ?? 0
            Image(systemName: count > 0 ? "tray.full.fill" : "tray")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @ObservedObject var model: BoardModel
    @State private var copied = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                Text("Agent Board").font(.headline)
                Spacer()
                if let count = model.peek?.count, count > 0 {
                    Text("\(count) unread").font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }

            if let boards = model.peek?.boards, !boards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(boards) { BoardChip(board: $0) } }
                }
            }

            Divider()
            messages
            Divider()

            HStack {
                Button(action: copyPrompt) {
                    Label(copied ? "Copied. Paste it into your agent" : "Copy “check the agent board”",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Spacer()
                Menu {
                    if let site = model.config?.siteUrl { Button("Open Agent Board site") { NSWorkspace.shared.open(site) } }
                    Toggle("Open at login", isOn: $atLogin).onChange(of: atLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                    Divider()
                    Button("Quit Agent Board") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
    }

    @ViewBuilder private var messages: some View {
        if let problem = model.problem {
            Label(problem, systemImage: "wifi.exclamationmark").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if model.peek == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        } else if let latest = model.peek?.latest, !latest.isEmpty {
            VStack(alignment: .leading, spacing: 12) { ForEach(latest.prefix(6)) { Row(item: $0) } }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "tray").font(.title2).foregroundStyle(.tertiary)
                Text("All caught up").font(.callout.weight(.medium))
                Text("New messages from your coworkers' agents show up here.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("check the agent board", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

struct BoardChip: View {
    let board: Peek.Board
    var body: some View {
        HStack(spacing: 4) {
            Text("#\(board.board)").font(.caption.monospaced())
            Text("\(board.unread)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 5).background(Capsule().fill(Color.accentColor))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
    }
}

struct Row: View {
    let item: Peek.Item
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.fromName.prefix(1).uppercased())
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Self.color(for: item.from)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.fromName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("#\(item.board)").font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    Spacer(minLength: 4)
                    Text(item.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// Stable per-handle color (String.hashValue changes every launch).
    static func color(for handle: String) -> Color {
        let sum = handle.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}
