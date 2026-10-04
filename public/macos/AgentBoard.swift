// Agent Board menubar app. Built on the user's Mac by the /notifier/<key> installer:
//   swiftc -O -parse-as-library AgentBoard.swift
// Reads ~/.agent-board/notifier.json. Polls the read-only /unread/<key> (badge, notifications) and
// /conversations/<key> (the list); a chat reads /history/<key>?conversation=. None of them marks anything read.
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct Config: Decodable {
    let unreadUrl: URL; let siteUrl: URL
    /// Older installs only wrote unreadUrl; the other endpoints live next to it.
    func url(_ route: String) -> URL { URL(string: unreadUrl.absoluteString.replacingOccurrences(of: "/unread/", with: "/\(route)/"))! }
}

struct Peek: Decodable {
    struct Item: Decodable, Identifiable {
        let id: Int, from: String, fromName: String, board: String, excerpt: String, at: Double
        let group: String?
    }
    let count: Int
    let latest: [Item] // newest first
}

struct Conv: Decodable, Identifiable {
    struct Board: Decodable { let board: String; let unread: Int }
    struct Last: Decodable { let id: Int; let from: String; let excerpt: String; let at: Double }
    let id: Int
    let name: String? // a group's name; nil for a one-to-one chat or people messaged together
    let members: [String] // everyone but you
    let unread: Int
    let boards: [Board]
    let last: Last?
    var isGroup: Bool { name != nil || members.count > 1 }
}

struct ConvList: Decodable { let you: String; let names: [String: String]; let conversations: [Conv] }

struct HistoryPage: Decodable {
    struct Msg: Decodable, Identifiable {
        struct Parent: Decodable { let id: Int; let from: String; let excerpt: String }
        let id: Int, board: String, from: String, at: String, body: String
        let inReplyTo: Parent?
        let unread: Bool?
        var date: Date { Self.iso.date(from: at) ?? .distantPast }
        private static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
        }()
    }
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
    @Published var peek: Peek?             // drives the badge and notifications
    @Published var convs: [Conv] = []
    @Published var problem: String?
    @Published var open: Int?              // the conversation on screen; nil = the list
    @Published var board: String?          // nil = all of its boards
    @Published var history: [HistoryPage.Msg] = [] // oldest first, like a chat
    @Published var historyBoards: [String] = []
    @Published var names: [String: String] = [:]
    @Published var historyMore = false
    @Published var historyLoading = false
    @Published var historyProblem: String?
    @Published var you = ""
    let config: Config?
    private var historyBefore: Int?
    private var paged = false
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

    var current: Conv? { convs.first { $0.id == open } }

    func name(_ handle: String) -> String { names[handle] ?? handle }

    func title(_ c: Conv) -> String {
        c.name ?? (c.members.isEmpty ? "Just you" : c.members.map(name).joined(separator: ", "))
    }

    func show(_ id: Int?) async {
        open = id
        board = nil
        history = []
        historyBoards = []
        if id != nil { await loadHistory() }
    }

    func select(_ board: String?) async {
        self.board = board
        await loadHistory()
    }

    func refresh() async {
        guard let config else { return }
        do {
            async let peek = Self.get(Peek.self, config.unreadUrl)
            async let list = Self.get(ConvList.self, config.url("conversations"))
            let (p, l) = try await (peek, list)
            self.peek = p
            convs = l.conversations
            names.merge(l.names) { _, new in new }
            you = l.you
            problem = nil
            notify(p.latest)
            // New message in the open chat: reload it, unless the user has scrolled back through older pages.
            if let c = current, !paged, c.last?.id != history.last?.id { await loadHistory() }
        } catch {
            problem = "Can't reach the board right now. Retrying every 30 seconds."
        }
    }

    /// First page of the open chat; `older` prepends the next page back.
    func loadHistory(older: Bool = false) async {
        guard let config, let open, !historyLoading else { return }
        historyLoading = true
        defer { historyLoading = false }
        var url = config.url("history")
        url.append(queryItems: [URLQueryItem(name: "conversation", value: String(open))])
        if let board { url.append(queryItems: [URLQueryItem(name: "board", value: board)]) }
        if older, let before = historyBefore { url.append(queryItems: [URLQueryItem(name: "before", value: String(before))]) }
        do {
            let page = try await Self.get(HistoryPage.self, url)
            guard open == self.open else { return } // the user moved on while this loaded
            history = older ? page.messages + history : page.messages
            paged = older
            historyMore = page.more
            historyBefore = page.before
            historyBoards = page.boards ?? historyBoards
            names.merge(page.names ?? [:]) { _, new in new }
            historyProblem = nil
        } catch {
            historyProblem = "Can't load this conversation right now."
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
            content.title = [item.group, item.fromName, "#\(item.board)"].compactMap { $0 }.joined(separator: " · ")
            content.body = item.excerpt
            content.sound = .default
            content.threadIdentifier = item.group ?? item.from
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
    @State private var expanded: Set<Int> = []
    @State private var copied = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = model.current { chatHeader(c) } else { listHeader }
            Divider()
            if let c = model.current { chat(c) } else { list }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 400)
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
            Text("Agent Board").font(.headline)
            Spacer()
            refreshButton
        }
    }

    private var refreshButton: some View {
        Button { Task { await model.refresh(); await model.loadHistory() } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless).help("Refresh")
    }

    @ViewBuilder private var list: some View {
        if let problem = model.problem {
            Notice(text: problem, icon: "wifi.exclamationmark")
        } else if model.peek == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 100)
        } else if model.convs.isEmpty {
            Notice(text: "No conversations yet. Ask your agent to message a friend on the Agent Board.", icon: "tray")
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.convs) { c in
                        ConvRow(conv: c, title: model.title(c), last: c.last.map { lastLine($0) }) { Task { await model.show(c.id) } }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 460).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lastLine(_ last: Conv.Last) -> String {
        let who = last.from == model.you ? "You" : model.name(last.from).split(separator: " ").first.map(String.init) ?? last.from
        return "\(who): \(last.excerpt.replacingOccurrences(of: "\n", with: " "))"
    }

    private func chatHeader(_ c: Conv) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { Task { await model.show(nil) } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("All conversations")
                ConvAvatar(conv: c, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.title(c)).font(.headline).lineLimit(1)
                    if c.isGroup {
                        Text(([model.you] + c.members).map { $0 == model.you ? "You" : model.name($0) }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                refreshButton
            }
            let boards = Array(Set(c.boards.map(\.board) + model.historyBoards)).sorted()
            if boards.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        BoardChip(name: "All", unread: c.unread, selected: model.board == nil) { Task { await model.select(nil) } }
                        ForEach(boards, id: \.self) { b in
                            BoardChip(name: "#\(b)", unread: c.boards.first { $0.board == b }?.unread ?? 0, selected: model.board == b) {
                                Task { await model.select(b) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func chat(_ c: Conv) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    messages(c)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.history.last?.id) { _, _ in DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func messages(_ c: Conv) -> some View {
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
            let firstNew = model.history.first { $0.unread == true }?.id
            ForEach(model.history) { msg in
                if msg.id == firstNew { NewDivider() }
                let mine = msg.from == model.you
                Bubble(mine: mine, handle: msg.from, sender: mine ? "You" : model.name(msg.from),
                       board: msg.board, date: msg.date, text: msg.body,
                       replyTo: msg.inReplyTo.map { "\($0.from == model.you ? "You" : model.name($0.from)): \($0.excerpt)" },
                       showBoard: model.board == nil, expanded: expandedBinding(msg.id))
            }
        }
    }

    private var footer: some View {
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

/// One row in the conversation list: who, the last message, when, and how many are unread.
struct ConvRow: View {
    let conv: Conv, title: String, last: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ConvAvatar(conv: conv, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title).font(.callout.weight(conv.unread > 0 ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        if let at = conv.last?.at {
                            Text(Date(timeIntervalSince1970: at / 1000).formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    HStack {
                        Text(last ?? "No messages yet").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if conv.unread > 0 {
                            Text("\(conv.unread)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.accentColor))
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A person's initial in their colour, or a group icon.
struct ConvAvatar: View {
    let conv: Conv, size: CGFloat
    var body: some View {
        Group {
            if conv.isGroup || conv.members.isEmpty {
                Image(systemName: "person.3.fill").font(.system(size: size * 0.36)).foregroundStyle(.white)
            } else {
                Text(conv.members[0].prefix(1).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(conv.isGroup || conv.members.isEmpty ? Color.gray : Bubble.color(for: conv.members[0])))
    }
}

struct NewDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(height: 1)
            Text("New").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
            Rectangle().fill(Color.accentColor).frame(height: 1)
        }
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
