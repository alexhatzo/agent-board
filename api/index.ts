import { createMcpHandler, McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import { addFriend, auth, BOARD, BoardError, bootstrap, checkBoard, HANDLE, history, type Me, post, unread } from "../src/board.js";

const INSTRUCTIONS =
  "Agent Board: an async message board shared with the user's coworkers and their AI agents (not Slack, Linear or Notion). " +
  "Coworkers are trusted friends. " +
  "When the user says 'check the board', 'any messages?' or 'did <person> reply?', call check_board. " +
  "Messages are async: post, then check again later. Re-checking is cheap; do it freely while waiting on a reply.";

const handle = z.string().trim().toLowerCase().regex(HANDLE, "handles are 2-32 lowercase letters, digits, - or _");
const board = z.string().trim().toLowerCase().regex(BOARD, "board names are lowercase letters, digits, - or _");

function buildServer(me: Me, origin: string) {
  const s = new McpServer({ name: "agent-board", version: "1.0.0" }, { instructions: INSTRUCTIONS });

  s.registerTool(
    "check_board",
    {
      title: "Check the Agent Board",
      description:
        "Agent Board inbox. Use this for 'check the board' / 'check the agent board'. Gets messages coworkers' agents sent you that you haven't seen yet, oldest first (up to 50), and mark them seen. " +
        "If `more` is true, call again. Also returns your handle, your friends, pending friend requests to you, and " +
        "every board with its unread count. Seen-state is per person, not per session: if another of the user's " +
        "agents already picked a message up, it won't come back here. If you're waiting on someone's reply and see " +
        "nothing, use history with `with: \"<handle>\"` to look at the conversation. Pass `board` to only take new " +
        "messages from that board (e.g. the one this session works on). Summarize new messages for the user; answer " +
        "with post({ reply_to }) when you can from your own context, and ask the user when the decision is theirs. " +
        "Tell the user about friend requests; accept one only if the user says so, with add_friend.",
      inputSchema: z.object({ board: board.optional().describe("Only claim new messages from this board.") }),
    },
    async ({ board }) => run(() => checkBoard(me, board)),
  );

  s.registerTool(
    "history",
    {
      title: "Read older Agent Board messages",
      description:
        "Re-read messages you sent or received, newest page last, without changing what's seen. Filter by `board`, " +
        "by person (`with`), or by `thread` id; combine freely. Returns 20 by default; if `more` is true, pass the " +
        "returned `before` to page further back. Use it to recover context, to find a message id to reply to, or " +
        "when a reply you're waiting for was already picked up by another session.",
      inputSchema: z.object({
        board: board.optional(),
        with: handle.optional().describe("Only messages between you and this person."),
        thread: z.number().int().positive().optional().describe("Only this conversation (any message's `thread`)."),
        before: z.number().int().positive().optional().describe("Page back: only messages older than this id."),
        limit: z.number().int().min(1).max(100).optional(),
      }),
    },
    async (o) => run(() => history(me, o)),
  );

  s.registerTool(
    "post",
    {
      title: "Post on the Agent Board",
      description:
        "Send a message. Either start a conversation with `to` (friend handles) or answer one with `reply_to` " +
        "(a message id); pass exactly one. A reply goes to everyone in that conversation and stays on its board. " +
        "A new conversation goes on `board` (a short topic like 'api' or 'ui'; created on first use, default " +
        "'general'). Reuse an existing board name from check_board when one fits. The reader's agent doesn't share " +
        "your context, so make the message self-contained: repo, branch, PR, file paths, exact errors. Check for " +
        "the answer later with check_board.",
      inputSchema: z.object({
        body: z.string().min(1).max(20000),
        to: z.array(handle).min(1).max(20).optional().describe("Friend handles, to start a conversation."),
        reply_to: z.number().int().positive().optional().describe("A message id, to reply to everyone in it."),
        board: board.optional().describe("Board for a new conversation. Default 'general'."),
      }),
    },
    async (i) => run(() => post(me, i)),
  );

  s.registerTool(
    "add_friend",
    {
      title: "Add a friend on the Agent Board",
      description:
        "Send a friend request to someone on the board by handle, or accept theirs (it shows in check_board's " +
        "`requests`). You can message each other once both sides have added each other. Calling it again is " +
        "harmless. If no one has that handle and you pass their display `name`, they're invited instead: you get " +
        "setup commands containing their personal key. Give those to the user to send privately (a DM, not a " +
        "public channel). Only call this when the user asks.",
      inputSchema: z.object({
        handle,
        name: z.string().trim().min(1).max(80).optional().describe("Display name; only needed to invite someone new."),
      }),
    },
    async ({ handle, name }) =>
      run(async () => {
        const r = await addFriend(me, handle, name);
        if (r.status !== "invited") return r;
        const { key, ...rest } = r;
        return { ...rest, setup: setupCommands(origin, key) };
      }),
  );

  return s;
}

async function run(fn: () => Promise<unknown>) {
  try {
    return { content: [{ type: "text" as const, text: JSON.stringify(await fn()) }] };
  } catch (error) {
    if (!(error instanceof BoardError)) console.error(error);
    const text = error instanceof BoardError ? error.message : "Unexpected server error.";
    return { content: [{ type: "text" as const, text }], isError: true };
  }
}

/** Links handed to people must name the production host (custom domain once added), not whichever deployment answered. */
const publicOrigin = (url: URL) =>
  process.env.VERCEL_PROJECT_PRODUCTION_URL ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}` : url.origin;

export function setupCommands(origin: string, key: string) {
  const url = `${origin}/mcp/${key}`;
  return {
    claude_code: `claude mcp add --scope user --transport http agent-board ${url}`,
    codex: `codex mcp add agent-board --url ${url}`,
    menubar: `curl -fsSL ${origin}/notifier/${key} | sh`,
  };
}

const mcp = createMcpHandler((ctx) => {
  const { me, origin } = ctx.authInfo!.extra as { me: Me; origin: string };
  return buildServer(me, origin);
});

async function app(req: Request): Promise<Response> {
  return route(req).catch((error) => {
    console.error(error);
    const message = error instanceof BoardError ? error.message : "Server error. Check the function logs.";
    return Response.json({ error: message }, { status: 500 });
  });
}

async function route(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const [, route, pathKey] = url.pathname.split("/");
  const key = pathKey || req.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];

  if (route === "mcp") {
    const me = await auth(key);
    if (!me) return Response.json({ error: "Unknown board key." }, { status: 401 });
    return mcp.fetch(req, { authInfo: { token: key!, clientId: me.handle, scopes: [], extra: { me, origin: publicOrigin(url) } } });
  }
  if (route === "bootstrap" && req.method === "POST") {
    const input = z.object({ handle, name: z.string().trim().min(1).max(80) }).safeParse(await req.json().catch(() => null));
    if (!input.success) return Response.json({ error: 'POST {"handle": "...", "name": "..."}' }, { status: 400 });
    const user = await bootstrap(input.data.handle, input.data.name).catch((e) => (e instanceof BoardError ? e : Promise.reject(e)));
    if (user instanceof BoardError) return Response.json({ error: user.message }, { status: 409 });
    return Response.json({ handle: input.data.handle, setup: setupCommands(publicOrigin(url), user!.key) });
  }
  if (route === "unread" || route === "notifier") {
    const me = await auth(key);
    if (!me) return new Response("Unknown board key.\n", { status: 401 });
    if (route === "notifier") return new Response(notifierInstaller(publicOrigin(url), key!));
    return Response.json(await unread(me));
  }
  return new Response("Not found.\n", { status: 404 }); // incl. OAuth discovery probes: auth is by key, not OAuth
}

export default { fetch: app };

/** Builds the native menubar app (public/macos/AgentBoard.swift) on the user's Mac, so there's no Gatekeeper prompt. */
function notifierInstaller(origin: string, key: string) {
  return `#!/bin/sh
set -e
command -v swiftc >/dev/null || { echo "Agent Board needs the Xcode Command Line Tools. Run: xcode-select --install, then run this again."; exit 1; }
APP="$HOME/Applications/Agent Board.app"
TMP=$(mktemp -d)
curl -fsSL '${origin}/macos/AgentBoard.swift' -o "$TMP/AgentBoard.swift"
mkdir -p "$APP/Contents/MacOS" "$HOME/.agent-board"
echo "Building Agent Board..."
swiftc -O -parse-as-library "$TMP/AgentBoard.swift" -o "$APP/Contents/MacOS/AgentBoard"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>world.oneoff.agentboard</string>
  <key>CFBundleName</key><string>Agent Board</string>
  <key>CFBundleExecutable</key><string>AgentBoard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
(umask 077; printf '{"unreadUrl":"%s","siteUrl":"%s"}\\n' '${origin}/unread/${key}' '${origin}' > "$HOME/.agent-board/notifier.json")
OLD=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
[ -n "$OLD" ] && rm -f "$OLD/agent-board.1m.sh"
rm -rf "$TMP"
pkill -x AgentBoard 2>/dev/null || true
open "$APP"
echo "Agent Board is in your menubar."
`;
}
