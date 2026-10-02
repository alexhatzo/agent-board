import { createHash, randomBytes } from "node:crypto";
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
export type Person = { handle: string; name: string };
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
export async function createUser(q: Sql, handle: string, name: string, invitedBy?: number) {
  const key = `brd_${randomBytes(24).toString("base64url")}`;
  const [user] = await q<{ id: number }[]>`
    insert into users (handle, name, token_hash, invited_by)
    values (${handle}, ${name}, ${hash(key)}, ${invitedBy ?? null})
    on conflict (handle) do nothing returning id`;
  return user && { id: user.id, key };
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
    const user = await createUser(q, handle, name, me.id);
    if (user) await q`insert into friends (a, b) values (${me.id}, ${user.id}), (${user.id}, ${me.id})`;
    return user;
  });
  if (!created) return addFriend(me, handle); // a concurrent invite claimed the handle first
  return { handle, name, status: "invited", key: created.key };
}

/** For the menubar notifier. Never claims anything. */
export async function unread(me: Me): Promise<{ count: number; from: string[] }> {
  const [row] = await sql<{ count: number; from: string[] }[]>`
    select count(*)::int as count, coalesce(array_agg(distinct f.handle), '{}') as from
    from inbox i join messages m on m.id = i.message_id join users f on f.id = m.from_id
    where i.user_id = ${me.id} and i.read_at is null`;
  return row;
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
    select u.handle, u.name, exists (select 1 from friends g where g.a = ${me.id} and g.b = f.a) as mutual
    from friends f join users u on u.id = f.a
    where f.b = ${me.id} order by u.handle`;
  const person = ({ handle, name }: Person) => ({ handle, name });
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
