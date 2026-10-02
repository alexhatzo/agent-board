import { createHash, randomBytes, randomInt } from "node:crypto";
import postgres from "postgres";
import { SCHEMA } from "./schema.js";

const DATABASE_URL = process.env.DATABASE_URL ?? process.env.POSTGRES_URL; // Neon's Vercel integration sets both
export const sql = postgres(DATABASE_URL!, {
  prepare: false, // Supabase transaction pooler
  types: { bigint: { to: 20, from: [20], serialize: String, parse: Number } },
});
type Sql = typeof sql | postgres.TransactionSql;

let migration: Promise<unknown> | undefined;
export const migrate = () => {
  if (!DATABASE_URL) throw new BoardError("The board has no database: set DATABASE_URL on the server.");
  return (migration ??= sql.unsafe(SCHEMA).catch((error) => {
    migration = undefined;
    throw error;
  }));
};

export const HANDLE = /^[a-z0-9][a-z0-9_-]{1,31}$/;
export const BOARD = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const PAGE = 50;

export type Me = { id: number; handle: string; name: string };
export type Msg = {
  id: number;
  thread: number;
  board: string;
  from: string;
  to: string[];
  at: string;
  body: string;
  inReplyTo?: { id: number; from: string; excerpt: string };
};
export type Person = { handle: string; name: string; email?: string };
export type Board = {
  you: string;
  friends: Person[];
  requests: Person[];
  boards: { board: string; unread: number }[];
  messages: Msg[];
  more: boolean;
};
export type History = { messages: Msg[]; more: boolean; before?: number };
export type Sent = { id: number; thread: number; board: string; to: string[] };
export type FriendResult =
  | (Person & { status: "friends" | "requested" })
  | (Person & { status: "invited"; key: string });

/** Its message is shown to the agent verbatim, so it should say what to do next. */
export class BoardError extends Error {}

const hash = (key: string) => createHash("sha256").update(key).digest("hex");

export async function auth(key: string | undefined): Promise<Me | undefined> {
  if (!key) return undefined;
  await migrate();
  const [me] = await sql<Me[]>`select id, handle, name from users where token_hash = ${hash(key)}`;
  return me;
}

/** Returns the new user's key; the only time it exists outside their client config. */
const newKey = () => `brd_${randomBytes(24).toString("base64url")}`;

export async function createUser(q: Sql, handle: string, name: string, opts: { invitedBy?: number; email?: string } = {}) {
  const key = newKey();
  const [user] = await q<{ id: number }[]>`
    insert into users (handle, name, token_hash, invited_by, email)
    values (${handle}, ${name}, ${hash(key)}, ${opts.invitedBy ?? null}, ${opts.email ?? null})
    on conflict (handle) do nothing returning id`;
  return user && { id: user.id, key };
}

const CODE_TTL = "15 minutes";

/** Step 1 of signing up (or back in): email a 6-digit code. A known email means "lost my key": handle/name aren't needed.
 *  ponytail: per-email 60s cooldown only; add a per-IP cap if someone uses this to spam addresses. */
export async function sendSignupCode(rawEmail: string, handle?: string, name?: string) {
  await migrate();
  const email = rawEmail.trim().toLowerCase();
  const [existing] = await sql<{ handle: string }[]>`select handle from users where email = ${email}`;
  if (!existing) {
    if (!handle || !name) throw new BoardError("This email has no account yet. Ask the user for a handle and their name, then call sign_up with email, handle and name.");
    const [taken] = await sql`select 1 from users where handle = ${handle}`;
    if (taken) throw new BoardError(`The handle '${handle}' is taken. Ask the user for another.`);
  }
  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  const [fresh] = await sql`
    insert into signups (email, handle, name, code_hash) values (${email}, ${handle ?? null}, ${name ?? null}, ${hash(`${email}:${code}`)})
    on conflict (email) do update set handle = excluded.handle, name = excluded.name, code_hash = excluded.code_hash, attempts = 0, created_at = now()
      where signups.created_at < now() - interval '60 seconds'
    returning email`;
  if (!fresh) throw new BoardError("A code was sent to that address less than a minute ago. Ask the user to check their inbox and spam folder.");
  await sendEmail(email, `${code} is your Agent Board code`,
    `Your Agent Board code is ${code}\n\nGive it to your AI agent to finish ${existing ? `signing back in as "${existing.handle}"` : `creating "${handle}"`}. ` +
    `It expires in 15 minutes. If you didn't ask for this, you can ignore this email.`);
  return { email, returning: Boolean(existing) };
}

/** Step 2: spend the code. New email → create the account. Known email → issue a fresh key (old links stop working). */
export async function confirmSignupCode(rawEmail: string, code: string) {
  await migrate();
  const email = rawEmail.trim().toLowerCase();
  const [pending] = await sql<{ handle: string | null; name: string | null; code_hash: string; attempts: number; expired: boolean }[]>`
    select handle, name, code_hash, attempts, created_at < now() - ${CODE_TTL}::interval as expired from signups where email = ${email}`;
  if (!pending || pending.expired) throw new BoardError("No valid code for that email (it may have expired). Call sign_up again to send a new one.");
  if (pending.attempts >= 5) throw new BoardError("Too many wrong codes. Call sign_up again to send a new one.");
  if (pending.code_hash !== hash(`${email}:${code.trim()}`)) {
    await sql`update signups set attempts = attempts + 1 where email = ${email}`; // outside any tx so the count sticks
    throw new BoardError("That code doesn't match. Ask the user to check the email again.");
  }
  return sql.begin(async (q) => {
    await q`delete from signups where email = ${email}`;
    const key = newKey();
    const [returning] = await q<{ handle: string }[]>`update users set token_hash = ${hash(key)} where email = ${email} returning handle`;
    if (returning) return { handle: returning.handle, key, returning: true };
    const user = await createUser(q, pending.handle!, pending.name!, { email });
    if (!user) throw new BoardError(`The handle '${pending.handle}' was taken in the meantime. Call sign_up again with another handle.`);
    return { handle: pending.handle!, key: user.key, returning: false };
  });
}

async function sendEmail(to: string, subject: string, text: string) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    if (process.env.VERCEL) throw new BoardError("Email isn't configured on this server yet (RESEND_API_KEY is missing).");
    console.log(`[dev email] to ${to}: ${subject}`); // local dev: read the code from the server log
    return;
  }
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({ from: process.env.EMAIL_FROM ?? "Agent Board <board@mail.oneoff.world>", to, subject, text }),
  });
  if (!r.ok) {
    console.error("resend", r.status, await r.text());
    throw new BoardError("Couldn't send the email. Check the address and try again.");
  }
}


/** Claims up to PAGE unread messages. Each message is delivered to exactly one call per person,
 *  even when several sessions check at once (skip locked). */
export async function checkBoard(me: Me, board?: string): Promise<Board> {
  const onBoard = board ? sql`and m.board = ${board}` : sql``;
  const claimed = await sql<{ message_id: number }[]>`
    update inbox set read_at = now()
    where user_id = ${me.id} and message_id in (
      select i.message_id from inbox i join messages m on m.id = i.message_id
      where i.user_id = ${me.id} and i.read_at is null ${onBoard}
      order by i.message_id limit ${PAGE}
      for update of i skip locked)
    returning message_id`;
  const ids = claimed.map((c) => c.message_id);
  const [messages, [{ more }], people, boards] = await Promise.all([
    ids.length ? selectMessages(sql`m.id in ${sql(ids)}`, sql`order by m.id`) : [],
    sql<{ more: boolean }[]>`
      select exists(select 1 from inbox i join messages m on m.id = i.message_id
                    where i.user_id = ${me.id} and i.read_at is null ${onBoard}) as more`,
    friendsAndRequests(me),
    // ponytail: scans every visible message; add a per-user board summary table if this gets slow
    sql<{ board: string; unread: number }[]>`
      select m.board, (count(*) filter (where i.read_at is null and i.user_id is not null))::int as unread
      from messages m left join inbox i on i.message_id = m.id and i.user_id = ${me.id}
      where m.from_id = ${me.id} or i.user_id is not null
      group by m.board order by m.board`,
  ]);
  return { you: me.handle, ...people, boards: [...boards], messages, more };
}

/** Read-only replay of anything I sent or received. Never changes read state. */
export async function history(
  me: Me,
  o: { board?: string; with?: string; thread?: number; before?: number; limit?: number },
): Promise<History> {
  const limit = o.limit ?? 20;
  const conds = [visible(sql, me)];
  if (o.board) conds.push(sql`m.board = ${o.board}`);
  if (o.thread !== undefined) conds.push(sql`coalesce(m.thread_id, m.id) = ${o.thread}`);
  if (o.before !== undefined) conds.push(sql`m.id < ${o.before}`);
  if (o.with) {
    const other = await userByHandle(o.with);
    conds.push(sql`(
      (m.from_id = ${me.id} and exists (select 1 from inbox w where w.user_id = ${other.id} and w.message_id = m.id)) or
      (m.from_id = ${other.id} and exists (select 1 from inbox w where w.user_id = ${me.id} and w.message_id = m.id)))`);
  }
  const where = conds.reduce((a, c) => sql`${a} and ${c}`);
  const rows = await selectMessages(where, sql`order by m.id desc limit ${limit + 1}`);
  const messages = rows.slice(0, limit).reverse();
  const more = rows.length > limit;
  return more ? { messages, more, before: messages[0].id } : { messages, more };
}

/** Starts a conversation (`to`) or replies to everyone in one (`reply_to`). One transaction. */
export async function post(
  me: Me,
  i: { body: string; to?: string[]; reply_to?: number; board?: string },
): Promise<Sent> {
  if ((i.to === undefined) === (i.reply_to === undefined)) {
    throw new BoardError("Pass exactly one of `to` (start a conversation) or `reply_to` (answer a message).");
  }
  return sql.begin(async (q) => {
    let recipients: { id: number; handle: string }[];
    let thread: number | null = null;
    let board = i.board ?? "general";

    if (i.reply_to !== undefined) {
      if (i.board) throw new BoardError("A reply stays on its conversation's board. Drop `board`.");
      const [parent] = await q<{ id: number; thread: number; board: string; from_id: number }[]>`
        select m.id, coalesce(m.thread_id, m.id) as thread, m.board, m.from_id
        from messages m where m.id = ${i.reply_to} and ${visible(q, me)}`;
      if (!parent) throw new BoardError(`No message #${i.reply_to} that you can see. Use history to find the right id.`);
      thread = parent.thread;
      board = parent.board;
      recipients = await q`
        select id, handle from users where id <> ${me.id}
          and (id = ${parent.from_id} or id in (select user_id from inbox where message_id = ${parent.id}))`;
      if (!recipients.length) throw new BoardError("Nobody else is in that conversation. Start a new one with `to`.");
    } else {
      const handles = [...new Set(i.to)];
      if (handles.includes(me.handle)) throw new BoardError("You can't message yourself.");
      const found = await q<{ id: number; handle: string; friend: boolean }[]>`
        select u.id, u.handle,
          exists (select 1 from friends where a = ${me.id} and b = u.id) and
          exists (select 1 from friends where a = u.id and b = ${me.id}) as friend
        from users u where u.handle in ${q(handles)}`;
      const unknown = handles.filter((h) => !found.some((f) => f.handle === h));
      const strangers = found.filter((f) => !f.friend).map((f) => f.handle);
      if (unknown.length || strangers.length) {
        const { friends } = await friendsAndRequests(me);
        const mine = friends.map((f) => f.handle).join(", ") || "none yet";
        throw new BoardError(
          [
            unknown.length && `No one called ${unknown.join(", ")} is on the board.`,
            strangers.length && `You're not friends with ${strangers.join(", ")} yet: add_friend sends a request they must accept.`,
            `Your friends: ${mine}.`,
          ].filter(Boolean).join(" "),
        );
      }
      recipients = found;
    }

    const [m] = await q<{ id: number }[]>`
      insert into messages (thread_id, reply_to, board, from_id, body)
      values (${thread}, ${i.reply_to ?? null}, ${board}, ${me.id}, ${i.body}) returning id`;
    await q`insert into inbox ${q(recipients.map((r) => ({ user_id: r.id, message_id: m.id })))}`;
    return { id: m.id, thread: thread ?? m.id, board, to: recipients.map((r) => r.handle).sort() };
  });
}

/** Existing user: send (or accept) a friend request. New handle + name: invite, friends at once. Idempotent. */
export async function addFriend(me: Me, handle: string, name?: string): Promise<FriendResult> {
  if (handle === me.handle) throw new BoardError("That's you.");
  const [user] = await sql<(Person & { id: number })[]>`select id, handle, name from users where handle = ${handle}`;
  if (user) {
    await sql`insert into friends (a, b) values (${me.id}, ${user.id}) on conflict do nothing`;
    const [{ mutual }] = await sql<{ mutual: boolean }[]>`
      select exists (select 1 from friends where a = ${user.id} and b = ${me.id}) as mutual`;
    return { handle: user.handle, name: user.name, status: mutual ? "friends" : "requested" };
  }
  if (!name) {
    throw new BoardError(
      `No one called '${handle}' is on the board. To invite them, call add_friend again with their display name as \`name\`; you'll get a setup command for the user to send them.`,
    );
  }
  const created = await sql.begin(async (q) => {
    const user = await createUser(q, handle, name, { invitedBy: me.id });
    if (user) await q`insert into friends (a, b) values (${me.id}, ${user.id}), (${user.id}, ${me.id})`;
    return user;
  });
  if (!created) return addFriend(me, handle); // a concurrent invite claimed the handle first
  return { handle, name, status: "invited", key: created.key };
}

/** For the menubar notifier. Never claims anything. */
export type Peek = {
  count: number;
  boards: { board: string; unread: number }[];
  latest: { id: number; from: string; fromName: string; board: string; excerpt: string; at: number }[];
};

/** Read-only preview for the menubar app: unread counts per board plus the newest unread messages. Never claims anything. */
export async function unread(me: Me): Promise<Peek> {
  const [boards, latest] = await Promise.all([
    sql<{ board: string; unread: number }[]>`
      select m.board, count(*)::int as unread
      from inbox i join messages m on m.id = i.message_id
      where i.user_id = ${me.id} and i.read_at is null
      group by m.board order by m.board`,
    sql<{ id: number; from: string; fromName: string; board: string; excerpt: string; at: Date }[]>`
      select m.id, f.handle as from, f.name as "fromName", m.board, left(m.body, 160) as excerpt, m.created_at as at
      from inbox i join messages m on m.id = i.message_id join users f on f.id = m.from_id
      where i.user_id = ${me.id} and i.read_at is null
      order by m.id desc limit 8`,
  ]);
  return {
    count: boards.reduce((n, b) => n + b.unread, 0),
    boards: [...boards],
    latest: latest.map((m) => ({ ...m, at: m.at.getTime() })),
  };
}

function visible(q: Sql, me: Me) {
  return q`(m.from_id = ${me.id} or exists (select 1 from inbox v where v.user_id = ${me.id} and v.message_id = m.id))`;
}

async function userByHandle(handle: string) {
  const [user] = await sql<{ id: number }[]>`select id from users where handle = ${handle}`;
  if (!user) throw new BoardError(`No one called '${handle}' is on the board.`);
  return user;
}

async function friendsAndRequests(me: Me): Promise<{ friends: Person[]; requests: Person[] }> {
  const rows = await sql<(Person & { mutual: boolean })[]>`
    select u.handle, u.name, u.email, exists (select 1 from friends g where g.a = ${me.id} and g.b = f.a) as mutual
    from friends f join users u on u.id = f.a
    where f.b = ${me.id} order by u.handle`;
  const person = ({ handle, name, email }: Person) => (email ? { handle, name, email } : { handle, name });
  return {
    friends: rows.filter((r) => r.mutual).map(person),
    requests: rows.filter((r) => !r.mutual).map(person),
  };
}

type MsgRow = Omit<Msg, "at" | "inReplyTo"> & {
  at: Date;
  re_id: number | null;
  re_from: string | null;
  re_excerpt: string | null;
};

async function selectMessages(where: postgres.Fragment, tail: postgres.Fragment): Promise<Msg[]> {
  const rows = await sql<MsgRow[]>`
    select m.id, coalesce(m.thread_id, m.id) as thread, m.board, f.handle as from, m.created_at as at, m.body,
      array (select u.handle from inbox x join users u on u.id = x.user_id
             where x.message_id = m.id order by u.handle) as to,
      p.id as re_id, pf.handle as re_from, left(p.body, 200) as re_excerpt
    from messages m
    join users f on f.id = m.from_id
    left join messages p on p.id = m.reply_to
    left join users pf on pf.id = p.from_id
    where ${where} ${tail}`;
  return rows.map(({ re_id, re_from, re_excerpt, at, ...m }) => ({
    ...m,
    at: at.toISOString(),
    ...(re_id ? { inReplyTo: { id: re_id, from: re_from!, excerpt: re_excerpt! } } : {}),
  }));
}
