// Applied idempotently on first DB use per instance, so a fresh database needs no manual step.
export const SCHEMA = `
create table if not exists users (
  id bigserial primary key,
  handle text unique not null check (handle ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  name text not null,
  token_hash text unique not null, -- sha256 hex of the key; the key itself is never stored
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
`;
