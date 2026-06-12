-- Recurring sessions: schema for Postgres / Supabase
--
-- Models recurring sessions where a slot can be cancelled and rematched to a
-- new provider without losing the history of who delivered what; where the
-- client portal, n8n and the Xero sync all write the same rows concurrently;
-- and where delivered sessions roll up into one Xero invoice per client/month,
-- with corrections handled as a void plus a fresh line (never an in-place edit).
--
-- Run with:  psql "$DATABASE_URL" -f schema.sql
--
-- gen_random_uuid() is built in on Postgres 13+ (incl. Supabase). On older
-- versions: create extension if not exists pgcrypto;

begin;

-- ---------------------------------------------------------------------------
-- Parties
-- ---------------------------------------------------------------------------
create table clients (
  client_id       uuid primary key default gen_random_uuid(),
  full_name       text not null,
  email           text unique,
  xero_contact_id text,                   -- this client's Xero contact (we invoice them)
  created_at      timestamptz not null default now()
);

create table service_providers (
  sp_id       uuid primary key default gen_random_uuid(),
  full_name   text not null,
  status      text not null default 'active'
              check (status in ('active', 'inactive')),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- The recurring arrangement (carries the price), and the slots it expands into
-- ---------------------------------------------------------------------------
create table engagements (
  engagement_id uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients,
  service_type  text not null,
  rrule         text,                       -- iCal RRULE for the recurrence
  rate_cents    int  not null check (rate_cents >= 0),   -- price per session
  currency      char(3) not null default 'AUD',
  status        text not null default 'active'
                check (status in ('active', 'paused', 'ended')),
  created_at    timestamptz not null default now()
);

create table sessions (
  session_id      uuid primary key default gen_random_uuid(),
  engagement_id   uuid not null references engagements,
  client_id       uuid not null references clients,
  sequence_no     int  not null,            -- nth session in the series
  scheduled_start timestamptz not null,
  scheduled_end   timestamptz not null,
  status          text not null default 'scheduled'
                  check (status in ('scheduled', 'completed', 'cancelled')),
  version         int  not null default 0,  -- optimistic-concurrency token
  created_at      timestamptz not null default now(),
  unique (engagement_id, sequence_no)       -- also indexes engagement_id
);

create index on sessions (client_id);

-- ---------------------------------------------------------------------------
-- Who held each slot. Append-style: one row per provider that ever held it.
-- ---------------------------------------------------------------------------
create table session_assignments (
  assignment_id  uuid primary key default gen_random_uuid(),
  session_id     uuid not null references sessions,
  sp_id          uuid not null references service_providers,
  status         text not null default 'assigned'
                 check (status in ('assigned', 'delivered', 'no_show', 'cancelled', 'rematched')),
  is_active      boolean not null default true,
  delivered_at   timestamptz,
  cancel_reason  text,
  superseded_by  uuid references session_assignments,   -- old row -> its replacement
  version        int  not null default 0,
  created_at     timestamptz not null default now()
);

-- The hard guarantee: at most one live assignment per session.
create unique index one_active_assignment_per_session
  on session_assignments (session_id) where is_active;

create index on session_assignments (session_id);   -- history lookups
create index on session_assignments (sp_id);

-- ---------------------------------------------------------------------------
-- Billing. One Xero invoice per client per month; delivered sessions become
-- its lines, so a month batches into a single invoice instead of one per
-- session. A correction voids the bad line (freeing the slot) and adds a
-- fresh one, rather than editing an invoice Xero has already issued.
-- ---------------------------------------------------------------------------
create table xero_invoices (
  xero_invoice_id uuid primary key default gen_random_uuid(),
  client_id    uuid not null references clients,
  period_month date not null,             -- first day of the billing month
  status       text not null default 'draft'
               check (status in ('draft', 'syncing', 'synced', 'failed')),
  xero_id      text,                       -- Xero's invoice id once created
  synced_at    timestamptz,
  created_at   timestamptz not null default now(),
  unique (client_id, period_month)         -- one invoice per client per month
);

create table invoice_lines (
  invoice_line_id uuid primary key default gen_random_uuid(),
  assignment_id   uuid not null references session_assignments,
  xero_invoice_id uuid references xero_invoices,        -- the monthly header it rolls into
  client_id       uuid not null references clients,
  sp_id           uuid not null references service_providers,
  amount_cents    int  not null check (amount_cents >= 0),  -- copied from the engagement at delivery
  currency        char(3) not null default 'AUD',
  status          text not null default 'issued'
                  check (status in ('issued', 'voided')),
  created_at      timestamptz not null default now()
);

-- One ISSUED line per delivered assignment. Because it's a partial index, a
-- correction can void the old line and insert a fresh one for the same slot.
create unique index one_issued_line_per_assignment
  on invoice_lines (assignment_id) where status = 'issued';

create index on invoice_lines (xero_invoice_id);

-- ---------------------------------------------------------------------------
-- Outbox: the single path that writes to Xero. The worker drains it.
-- ---------------------------------------------------------------------------
create table sync_outbox (
  outbox_id       bigint generated always as identity primary key,
  aggregate       text not null,            -- e.g. 'xero_invoice'
  aggregate_id    uuid not null,            -- xero_invoices.xero_invoice_id
  op              text not null check (op in ('create', 'update', 'finalise')),
  idempotency_key text not null unique,     -- dedupes retried enqueues
  status          text not null default 'pending'
                  check (status in ('pending', 'processing', 'done', 'failed')),
  attempts        int  not null default 0,
  last_error      text,
  created_at      timestamptz not null default now(),
  processed_at    timestamptz
);

-- The worker polls this; a partial index keeps the queue scan cheap.
create index sync_outbox_pending on sync_outbox (created_at) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Convenience views
-- ---------------------------------------------------------------------------

-- Who delivered what (one row per delivered session).
create view delivered_sessions as
select s.session_id,
       s.engagement_id,
       s.client_id,
       s.sequence_no,
       s.scheduled_start,
       a.sp_id        as delivered_by,
       sp.full_name   as provider_name,
       a.delivered_at
from sessions s
join session_assignments a on a.session_id = s.session_id
join service_providers  sp on sp.sp_id = a.sp_id
where a.status = 'delivered';

-- Full assignment trail for every slot (shows the cancel/rematch chain).
create view assignment_history as
select a.session_id,
       a.assignment_id,
       a.sp_id,
       a.status,
       a.is_active,
       a.superseded_by,
       a.created_at
from session_assignments a
order by a.session_id, a.created_at;

-- ---------------------------------------------------------------------------
-- Documentation
-- ---------------------------------------------------------------------------
comment on table  sessions is 'One scheduled occurrence (a slot in time); never edited after creation.';
comment on table  session_assignments is 'Every provider that has held a slot. Exactly one row is_active per session.';
comment on column session_assignments.superseded_by is 'On a rematch, points the closed row at its replacement.';
comment on table  xero_invoices is 'One invoice per client per month; delivered sessions become its lines.';
comment on table  invoice_lines is 'One issued line per delivered assignment; a void frees the slot for a correction.';
comment on table  sync_outbox is 'Append-only queue of Xero sync jobs; drained by a single idempotent worker.';

commit;
