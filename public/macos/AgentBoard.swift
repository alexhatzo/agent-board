// Agent Board menubar app. Built on the user's Mac by the /notifier/<key> installer:
//   swiftc -O -parse-as-library AgentBoard.swift
// Reads ~/.agent-board/notifier.json and polls the read-only /unread/<key> preview; the History tab reads
// /history/<key>. Neither ever marks anything read.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct Config: Decodable {
    let unreadUrl: URL; let siteUrl: URL
    /// Older installs only wrote unreadUrl; history lives next to it.
    var historyUrl: URL { URL(string: unreadUrl.absoluteString.replacingOccurrences(of: "/unread/", with: "/history/"))! }
}

struct Peek: Decodable {
    struct Board: Decodable, Identifiable { let board: String; let unread: Int; var id: String { board } }
    struct Item: Decodable, Identifiable {
        let id: Int, from: String, fromName: String, board: String, excerpt: String, at: Double
        let body: String? // absent from servers older than the History tab
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }
    let count: Int
    let boards: [Board]
    let latest: [Item]
}

struct HistoryPage: Decodable {
    struct Msg: Decodable, Identifiable {
        struct Parent: Decodable { let id: Int; let from: String; let excerpt: String }
        let id: Int, board: String, from: String, to: [String], at: String, body: String
        let inReplyTo: Parent?
        var date: Date { Self.iso.date(from: at) ?? .distantPast }
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
        }()
    }
    let you: String
    let messages: [Msg] // oldest first
    let more: Bool
    let before: Int?
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
    @Published var history: [HistoryPage.Msg] = [] // newest first
    @Published var historyMore = false
    @Published var historyLoading = false
    @Published var historyProblem: String?
    @Published var you = ""
    let config: Config?
    private var historyBefore: Int?
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
            let peek = try await Self.get(Peek.self, config.unreadUrl)
            self.peek = peek
            problem = nil
            notify(peek.latest)
        } catch {
            problem = "Can't reach the board right now. Retrying every 30 seconds."
        }
    }

    /// First page on open or refresh; `older` appends the next page back.
    func loadHistory(older: Bool = false) async {
        guard let config, !historyLoading else { return }
        historyLoading = true
        defer { historyLoading = false }
        var url = config.historyUrl
        if older, let before = historyBefore { url.append(queryItems: [URLQueryItem(name: "before", value: String(before))]) }
        do {
            let page = try await Self.get(HistoryPage.self, url)
            let newestFirst = Array(page.messages.reversed())
            history = older ? history + newestFirst : newestFirst
            historyMore = page.more
            historyBefore = page.before
            you = page.you
            historyProblem = nil
        } catch {
            historyProblem = "Can't load history right now. If this keeps happening, reinstall the menubar app from the Agent Board site."
        }
    }

    private static func get<T: Decodable>(_: T.Type, _ url: URL) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
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

enum Tab: Hashable { case unread, history }

struct Panel: View {
    @ObservedObject var model: BoardModel
    @State private var tab = Tab.unread
    @State private var expanded: Int?
    @State private var copied = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                Text("Agent Board").font(.headline)
                Spacer()
                Button {
                    Task { tab == .history ? await model.loadHistory() : await model.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }

            Picker("", selection: $tab) {
                Text(unreadLabel).tag(Tab.unread)
                Text("History").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: tab) { _, now in
                expanded = nil
                if now == .history { Task { await model.loadHistory() } }
            }

            if tab == .unread, let boards = model.peek?.boards, !boards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(boards) { BoardChip(board: $0) } }
                }
            }

            Divider()
            ScrollView {
                VStack { if tab == .unread { unread } else { history } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90, maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 380)
    }

    private var unreadLabel: String {
        let count = model.peek?.count ?? 0
        return count > 0 ? "Unread (\(count))" : "Unread"
    }

    @ViewBuilder private var unread: some View {
        if let problem = model.problem {
            Notice(text: problem, icon: "wifi.exclamationmark")
        } else if model.peek == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        } else if let latest = model.peek?.latest, !latest.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(latest) { item in
                    MessageRow(handle: item.from, title: item.fromName, board: item.board, date: item.date,
                               excerpt: item.excerpt, text: item.body ?? item.excerpt,
                               expanded: expandedBinding(item.id))
                }
                if let count = model.peek?.count, count > latest.count {
                    Text("\(count - latest.count) more unread. Ask your agent to check the board.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
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

    @ViewBuilder private var history: some View {
        if let problem = model.historyProblem, model.history.isEmpty {
            Notice(text: problem, icon: "exclamationmark.triangle")
        } else if model.history.isEmpty {
            if model.historyLoading { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
            else { Notice(text: "No messages yet. Sent and received messages show up here.", icon: "clock") }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.history) { msg in
                    let mine = msg.from == model.you
                    MessageRow(handle: msg.from,
                               title: mine ? "You → \(msg.to.joined(separator: ", "))" : msg.from,
                               board: msg.board, date: msg.date,
                               excerpt: msg.body, text: msg.body,
                               replyTo: msg.inReplyTo.map { "\($0.from): \($0.excerpt)" },
                               expanded: expandedBinding(msg.id))
                }
                if model.historyMore {
                    Button(model.historyLoading ? "Loading…" : "Load older") { Task { await model.loadHistory(older: true) } }
                        .buttonStyle(.borderless).font(.callout).disabled(model.historyLoading)
                        .frame(maxWidth: .infinity).padding(.top, 6)
                }
            }
        }
    }

    private func expandedBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { expanded == id }, set: { expanded = $0 ? id : nil })
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("check the agent board", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}

struct Notice: View {
    let text: String, icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
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

/// One message. Tap to expand to the full, selectable text.
struct MessageRow: View {
    let handle: String, title: String, board: String, date: Date, excerpt: String, text: String
    var replyTo: String? = nil
    @Binding var expanded: Bool
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(handle.prefix(1).uppercased())
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Self.color(for: handle)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("#\(board)").font(.caption.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                    Spacer(minLength: 4)
                    Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                if expanded {
                    if let replyTo {
                        Text("Re: \(replyTo)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                    }
                    Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(copied ? "Copied" : "Copy text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless).font(.caption)
                } else {
                    Text(excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggle)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(expanded ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)))
        .help(expanded ? "Click the header to collapse" : "Click to show the full message")
    }

    private func toggle() { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

    /// Stable per-handle color (String.hashValue changes every launch).
    static func color(for handle: String) -> Color {
        let sum = handle.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}
