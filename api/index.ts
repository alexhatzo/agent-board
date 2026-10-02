import { createMcpHandler, McpServer } from "@modelcontextprotocol/server";
import { z } from "zod";
import { addFriend, auth, BOARD, BoardError, bootstrap, checkBoard, HANDLE, history, type Me, post, unread } from "../src/board.js";

const INSTRUCTIONS =
  "An async message board shared with the user's coworkers and their AI agents. Coworkers are trusted friends. " +
  "When the user says 'check the board', 'any messages?' or 'did <person> reply?', call check_board. " +
  "Messages are async: post, then check again later. Re-checking is cheap; do it freely while waiting on a reply.";

const handle = z.string().trim().toLowerCase().regex(HANDLE, "handles are 2-32 lowercase letters, digits, - or _");
const board = z.string().trim().toLowerCase().regex(BOARD, "board names are lowercase letters, digits, - or _");

function buildServer(me: Me, origin: string) {
  const s = new McpServer({ name: "agent-board", version: "1.0.0" }, { instructions: INSTRUCTIONS });

  s.registerTool(
    "check_board",
    {
      title: "Check the message board",
      description:
        "Get messages coworkers sent you that you haven't seen yet, oldest first (up to 50), and mark them seen. " +
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
      title: "Read older messages",
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
      title: "Post a message",
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
      title: "Add a friend",
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
    claude_code: `claude mcp add --scope user --transport http board ${url}`,
    codex: `codex mcp add board --url ${url}`,
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
    if (route === "notifier") return new Response(notifierInstaller(`${url.origin}/unread/${key}`));
    const { count, from } = await unread(me);
    return new Response(`${count}\n${from.join(", ")}\n`);
  }
  return new Response("Not found.\n", { status: 404 }); // incl. OAuth discovery probes: auth is by key, not OAuth
}

export default { fetch: app };

/** SwiftBar plugin + installer. Handles are [a-z0-9_-], so $FROM is safe inside the AppleScript string. */
function notifierInstaller(unreadUrl: string) {
  return `#!/bin/sh
set -e
if [ ! -d /Applications/SwiftBar.app ]; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh) or SwiftBar (https://swiftbar.app) first."; exit 1; }
  brew install --cask swiftbar
fi
DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [ -z "$DIR" ]; then
  DIR="$HOME/.agent-board/swiftbar"
  defaults write com.ameba.SwiftBar PluginDirectory "$DIR"
fi
mkdir -p "$DIR"
cat > "$DIR/agent-board.1m.sh" <<'PLUGIN'
#!/bin/sh
OUT=$(curl -fsS --max-time 10 '${unreadUrl}') || { echo "✉ ?"; echo "---"; echo "Board unreachable"; exit 0; }
N=$(printf '%s\\n' "$OUT" | sed -n 1p)
FROM=$(printf '%s\\n' "$OUT" | sed -n 2p)
STATE="$HOME/.agent-board/last-unread"
LAST=$(cat "$STATE" 2>/dev/null || echo 0)
mkdir -p "$HOME/.agent-board" && echo "$N" > "$STATE"
[ "$N" -gt "$LAST" ] && osascript -e "display notification \\"from $FROM\\" with title \\"Agent board: $N unread\\" sound name \\"Glass\\""
[ "$N" -gt 0 ] && echo "✉ $N" || echo "✉"
echo "---"
[ "$N" -gt 0 ] && echo "$N unread from $FROM"
echo "Tell your agent: check the board"
PLUGIN
chmod +x "$DIR/agent-board.1m.sh"
open /Applications/SwiftBar.app  # by path: a cask installed seconds ago is not yet registered for -a
open -g "swiftbar://refreshallplugins" 2>/dev/null || true
echo "Agent board notifier installed in $DIR"
`;
}
