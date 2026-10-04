// Applied idempotently on first DB use per instance, so a fresh database needs no manual step.
export const SCHEMA = `
create table if not exists users (
  id bigserial primary key,
  handle text unique not null check (handle ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  name text not null,
  token_hash text unique, -- legacy single key; moved to the keys table on boot (see below)
  invited_by bigint references users(id),
  created_at timestamptz not null default now()
);

-- One row = "a added b". Friends = both directions exist; one direction = pending request.
create table if not exists friends (
  a bigint not null references users(id),
  b bigint not null references users(id),
  created_at timestamptz not null default now(),
  primary key (a, b),
  check (a <> b)
);

create table if not exists messages (
  id bigserial primary key,
  thread_id bigint references messages(id), -- null = this message starts the thread
  reply_to bigint references messages(id),
  board text not null default 'general' check (board ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  from_id bigint not null references users(id),
  body text not null check (length(body) between 1 and 20000),
  created_at timestamptz not null default now()
);
create index if not exists messages_from on messages (from_id, id);
create index if not exists messages_thread on messages (thread_id);

-- Recipients and read state: one row per (recipient, message). read_at is per person, not per session.
create table if not exists inbox (
  user_id bigint not null references users(id),
  message_id bigint not null references messages(id),
  read_at timestamptz,
  primary key (user_id, message_id)
);
create index if not exists inbox_unread on inbox (user_id, message_id) where read_at is null;
create index if not exists inbox_message on inbox (message_id);

-- Verified email: identity for friend requests + key recovery. Null for accounts created by invite.
alter table users add column if not exists email text;
create unique index if not exists users_email on users (email);

-- One pending code per email (POST /signup sends it, POST /confirm spends it).
create table if not exists signups (
  email text primary key,
  handle text,
  name text,
  code_hash text not null,
  attempts int not null default 0,
  created_at timestamptz not null default now()
);
alter table signups add column if not exists sends int not null default 1;
alter table signups add column if not exists window_start timestamptz not null default now();

-- One key per signed-in client (Claude Code, Codex, ...). Signing in on another client adds a row instead of replacing.
create table if not exists keys (
  token_hash text primary key, -- sha256 hex of the key
  user_id bigint not null references users(id),
  label text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists keys_user on keys (user_id);
-- Carry over pre-keys-table logins, then clear them so a revoked key can never be re-imported on a later boot.
alter table users alter column token_hash drop not null;
insert into keys (token_hash, user_id, label) select token_hash, id, 'first sign-in' from users where token_hash is not null on conflict do nothing;
update users set token_hash = null where token_hash is not null;

-- Conversations: a one-to-one chat (no name, two members) or a group (named, or several people messaged together).
-- Members see the whole history, including messages from before they joined.
create table if not exists conversations (
  id bigserial primary key,
  name text, -- null = one-to-one, or people messaged together with post({to: [...]})
  created_by bigint references users(id),
  created_at timestamptz not null default now()
);
create table if not exists members (
  conversation_id bigint not null references conversations(id),
  user_id bigint not null references users(id),
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index if not exists members_user on members (user_id);
alter table messages add column if not exists conversation_id bigint references conversations(id);
create index if not exists messages_conversation on messages (conversation_id, id);

-- Older messages (and any an old deployment writes mid-rollout) get the conversation of their exact participant set.
-- The lock keeps two cold-starting instances from creating the same conversation twice.
do $$
declare r record; cid bigint;
begin
  if not exists (select 1 from messages where conversation_id is null) then return; end if;
  perform pg_advisory_xact_lock(1389);
  for r in
    select array_agg(m.id) as ids, min(m.created_at) as at, p.people
    from messages m
    cross join lateral (select array(select distinct u from unnest(m.from_id || array(select user_id from inbox where message_id = m.id)) u order by u) as people) p
    where m.conversation_id is null
    group by p.people
  loop
    select c.id into cid from conversations c
    where c.name is null and array(select user_id from members where conversation_id = c.id order by user_id) = r.people
    limit 1;
    if cid is null then
      insert into conversations (created_at) values (r.at) returning id into cid;
      insert into members (conversation_id, user_id, joined_at) select cid, unnest(r.people), r.at;
    end if;
    update messages set conversation_id = cid where id = any(r.ids);
  end loop;
end $$;
`;
