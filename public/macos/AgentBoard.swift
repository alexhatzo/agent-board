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
        let body: String? // absent from older servers
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }
    let count: Int
    let boards: [Board]
    let latest: [Item] // newest first
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
    let boards: [String]?
    let names: [String: String]? // handle → display name
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
    @Published var peek: Peek?            // all boards: drives the badge and notifications
    @Published var filtered: Peek?        // the selected board's unread, when a filter is on
    @Published var problem: String?
    @Published var board: String?         // nil = all boards
    @Published var history: [HistoryPage.Msg] = [] // oldest first, like a chat
    @Published var historyBoards: [String] = []
    @Published var names: [String: String] = [:]
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
            await self?.loadHistory() // fills the board chips before anyone opens History
            while let self {
                await self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Unread messages on screen: the filtered board's, or everything.
    var unreadShown: [Peek.Item] { (board == nil ? peek : filtered)?.latest.reversed() ?? [] }

    /// Every board worth a filter chip: ones with unread plus ones in history.
    var allBoards: [String] { Array(Set((peek?.boards.map(\.board) ?? []) + historyBoards)).sorted() }

    func unreadCount(_ board: String) -> Int { peek?.boards.first { $0.board == board }?.unread ?? 0 }

    func select(_ board: String?) async {
        self.board = board
        filtered = nil
        await refresh()
        await loadHistory()
    }

    func refresh() async {
        guard let config else { return }
        do {
            let peek = try await Self.get(Peek.self, config.unreadUrl)
            self.peek = peek
            if let board { filtered = try await Self.get(Peek.self, Self.with(config.unreadUrl, board: board)) }
            problem = nil
            notify(peek.latest)
        } catch {
            problem = "Can't reach the board right now. Retrying every 30 seconds."
        }
    }

    /// First page on open or refresh; `older` prepends the next page back.
    func loadHistory(older: Bool = false) async {
        guard let config, !historyLoading else { return }
        historyLoading = true
        defer { historyLoading = false }
        var url = Self.with(config.historyUrl, board: board)
        if older, let before = historyBefore { url.append(queryItems: [URLQueryItem(name: "before", value: String(before))]) }
        do {
            let page = try await Self.get(HistoryPage.self, url)
            history = older ? page.messages + history : page.messages
            historyMore = page.more
            historyBefore = page.before
            historyBoards = page.boards ?? historyBoards
            names.merge(page.names ?? [:]) { _, new in new }
            you = page.you
            historyProblem = nil
        } catch {
            historyProblem = "Can't load history right now. If this keeps happening, reinstall the menubar app from the Agent Board site."
        }
    }

    private static func with(_ url: URL, board: String?) -> URL {
        guard let board else { return url }
        var url = url
        url.append(queryItems: [URLQueryItem(name: "board", value: board)])
        return url
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
    @State private var expanded: Set<Int> = []
    @State private var copied = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                Text("Agent Board").font(.headline)
                Spacer()
                Picker("", selection: $tab) {
                    Text(unreadLabel).tag(Tab.unread)
                    Text("History").tag(Tab.history)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: tab) { _, now in if now == .history { Task { await model.loadHistory() } } }
                Button {
                    Task { tab == .history ? await model.loadHistory() : await model.refresh() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }

            if !model.allBoards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        BoardChip(name: "All", unread: model.peek?.count ?? 0, selected: model.board == nil) {
                            Task { await model.select(nil) }
                        }
                        ForEach(model.allBoards, id: \.self) { b in
                            BoardChip(name: "#\(b)", unread: model.unreadCount(b), selected: model.board == b) {
                                Task { await model.select(b) }
                            }
                        }
                    }
                }
            }

            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if tab == .unread { unread } else { history }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 120, maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: tab) { _, _ in DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.board) { _, _ in DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
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
        .frame(width: 400)
    }

    private var unreadLabel: String {
        let count = model.peek?.count ?? 0
        return count > 0 ? "Unread (\(count))" : "Unread"
    }

    @ViewBuilder private var unread: some View {
        if let problem = model.problem {
            Notice(text: problem, icon: "wifi.exclamationmark")
        } else if model.peek == nil || (model.board != nil && model.filtered == nil) {
            ProgressView().frame(maxWidth: .infinity, minHeight: 100)
        } else if model.unreadShown.isEmpty {
            Notice(text: model.board.map { "Nothing unread on #\($0)." } ?? "All caught up. New messages from your coworkers' agents show up here.",
                   icon: "tray")
        } else {
            let shown = model.unreadShown
            let total = model.board.map(model.unreadCount) ?? model.peek?.count ?? 0
            if total > shown.count {
                Text("\(total - shown.count) older unread not shown. Ask your agent to check the board.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(shown) { item in
                Bubble(mine: false, handle: item.from, sender: item.fromName, board: item.board, date: item.date,
                       text: item.body ?? item.excerpt, showBoard: model.board == nil, expanded: expandedBinding(item.id))
            }
        }
    }

    @ViewBuilder private var history: some View {
        if let problem = model.historyProblem, model.history.isEmpty {
            Notice(text: problem, icon: "exclamationmark.triangle")
        } else if model.history.isEmpty {
            if model.historyLoading { ProgressView().frame(maxWidth: .infinity, minHeight: 100) }
            else { Notice(text: model.board.map { "No messages on #\($0) yet." } ?? "No messages yet.", icon: "clock") }
        } else {
            if model.historyMore {
                Button(model.historyLoading ? "Loading…" : "Load older") { Task { await model.loadHistory(older: true) } }
                    .buttonStyle(.borderless).font(.callout).disabled(model.historyLoading)
                    .frame(maxWidth: .infinity)
            }
            ForEach(model.history) { msg in
                let mine = msg.from == model.you
                let name = { (h: String) in model.names[h] ?? h }
                Bubble(mine: mine, handle: msg.from, sender: mine ? "To \(msg.to.map(name).joined(separator: ", "))" : name(msg.from),
                       board: msg.board, date: msg.date, text: msg.body,
                       replyTo: msg.inReplyTo.map { "\(name($0.from)): \($0.excerpt)" },
                       showBoard: model.board == nil, expanded: expandedBinding(msg.id))
            }
        }
    }

    private func expandedBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { on in if on { expanded.insert(id) } else { expanded.remove(id) } })
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
            .frame(maxWidth: .infinity, minHeight: 100)
    }
}

struct BoardChip: View {
    let name: String, unread: Int, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name).font(.caption.monospaced())
                if unread > 0 {
                    Text("\(unread)").font(.caption2.weight(.semibold)).foregroundStyle(selected ? Color.accentColor : .white)
                        .padding(.horizontal, 5).background(Capsule().fill(selected ? Color.white : Color.accentColor))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
    }
}

/// One chat bubble: yours on the right in the accent colour, everyone else's on the left.
struct Bubble: View {
    let mine: Bool, handle: String, sender: String, board: String, date: Date, text: String
    var replyTo: String? = nil
    var showBoard = true
    @Binding var expanded: Bool

    /// Long messages start collapsed; "Show more" opens them.
    private var long: Bool { text.count > 360 || text.filter { $0 == "\n" }.count > 6 }
    private var collapsed: Bool { long && !expanded }
    private func toggle() { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 48) } else { avatar }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(sender).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                VStack(alignment: .leading, spacing: 6) {
                    if let replyTo {
                        Text(replyTo).font(.caption).lineLimit(2).opacity(0.75)
                            .padding(.leading, 7)
                            .overlay(alignment: .leading) { Rectangle().frame(width: 2).opacity(0.4) }
                    }
                    // Selectable text ignores lineLimit when clicked, so collapsed text isn't selectable;
                    // a click on the bubble opens it instead, like "Show more".
                    if collapsed {
                        Text(text).font(.callout).lineLimit(6)
                    } else {
                        Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                .contentShape(Rectangle())
                .gesture(TapGesture().onEnded { toggle() }, including: collapsed ? .all : .subviews)
                .contextMenu {
                    Button("Copy message") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                HStack(spacing: 6) {
                    if showBoard { Text("#\(board)").font(.caption2.monospaced()) }
                    Text(date.formatted(.relative(presentation: .named))).font(.caption2)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                    if long {
                        Button(expanded ? "Show less" : "Show more", action: toggle)
                            .buttonStyle(.borderless).font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            if mine { avatar } else { Spacer(minLength: 48) }
        }
    }

    private var avatar: some View {
        Text(handle.prefix(1).uppercased())
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Self.color(for: handle)))
            .padding(.bottom, 18) // line up with the bubble, not the meta line under it
    }

    /// Stable per-handle color (String.hashValue changes every launch).
    static func color(for handle: String) -> Color {
        let sum = handle.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color(hue: Double(sum % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}
