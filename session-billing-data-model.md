# Data Model & Flow Design — Recurring Sessions → Xero Invoicing

**Stack:** Postgres / Supabase, n8n automation layer, Xero sync, client portal.

This document answers four things: (1) the core schema and how cancel‑and‑rematch preserves history, (2) how concurrent writers stay consistent and retries don't duplicate, (3) how a delivered session becomes a Xero invoice line exactly once, and (4) how to migrate to this with no downtime.

The single most important idea running through all four: **make the database the arbiter of truth, not the application.** Every "don't duplicate" guarantee below is enforced by a unique constraint or a row lock, never by application logic hoping it ran once.

---

## 1. Core data model

### Design principles

1. **Nothing that represents history is ever mutated in place.** Reassignment, cancellation, and rebooking are modelled as new rows, not `UPDATE`s that overwrite the past.
2. **The session is the billable unit of work**, but *who delivered it* is a separate, time‑bounded fact. Decoupling these is what lets a session be cancelled and rematched without losing the original SP.
3. **Money records (invoice lines) reference the exact assignment that delivered the work**, not just the session — so we always bill the SP who actually showed up.

### Entities

- `clients` — the customer booking sessions.
- `service_providers` — the SPs delivering them.
- `bookings` — the recurring agreement (a series). Generates many sessions.
- `sessions` — one scheduled occurrence. Carries the lifecycle state machine.
- `session_assignments` — **append‑only.** One row per (session → SP) assignment. This is where cancel‑and‑rematch history lives.
- `invoice_lines` — one billable line per delivered session.
- `xero_invoices` — header grouping lines into a Xero invoice (e.g. monthly per client).
- `sync_outbox` — transactional outbox driving the Xero push (see §3).

### DDL

```sql
-- Enums make illegal states unrepresentable and self-document the state machine.
create type session_status as enum (
  'scheduled', 'delivered', 'cancelled', 'no_show'
);

create type assignment_status as enum (
  'active', 'superseded', 'cancelled'
);

create type invoice_line_status as enum (
  'pending', 'synced', 'voided'
);

-- ---------------------------------------------------------------------------

create table clients (
  id           uuid primary key default gen_random_uuid(),
  display_name text not null,
  created_at   timestamptz not null default now()
);

create table service_providers (
  id           uuid primary key default gen_random_uuid(),
  display_name text not null,
  -- The SP's identity in Xero (contact). Set once Xero knows about them.
  xero_contact_id text,
  created_at   timestamptz not null default now()
);

-- The recurring agreement. A booking spawns many sessions.
create table bookings (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references clients(id),
  cadence      text not null,            -- e.g. 'weekly', 'fortnightly'
  rate_cents   integer not null,         -- price per delivered session
  currency     char(3) not null default 'GBP',
  created_at   timestamptz not null default now()
);

-- One scheduled occurrence. The billable unit of work.
create table sessions (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references bookings(id),
  scheduled_at   timestamptz not null,
  status         session_status not null default 'scheduled',
  -- If this session is the rematched replacement of a cancelled one,
  -- this chains back to the original so the full story is reconstructable.
  supersedes_session_id uuid references sessions(id),
  -- Optimistic-concurrency guard (see §2).
  version        integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- APPEND-ONLY. Each row is one SP's responsibility for one session.
-- Cancel-and-rematch = close the old row + insert a new one. Never deleted.
create table session_assignments (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references sessions(id),
  provider_id   uuid not null references service_providers(id),
  status        assignment_status not null default 'active',
  reason        text,                     -- why superseded/cancelled
  assigned_at   timestamptz not null default now(),
  ended_at      timestamptz                -- set when no longer active
);

-- THE KEY CONSTRAINT: at most one active assignment per session, ever,
-- even under concurrent rematch attempts. Enforced by the DB, not the app.
create unique index one_active_assignment_per_session
  on session_assignments (session_id)
  where status = 'active';

-- Each delivered session bills exactly once.
create table invoice_lines (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references sessions(id),
  -- bill against the assignment that actually delivered the work
  assignment_id uuid not null references session_assignments(id),
  xero_invoice_id uuid references xero_invoices(id),
  amount_cents  integer not null,
  currency      char(3) not null,
  status        invoice_line_status not null default 'pending',
  xero_line_id  text,                     -- Xero's id once pushed
  created_at    timestamptz not null default now()
);

-- THE NO-DOUBLE-BILL CONSTRAINT: one live invoice line per session.
-- A voided line releases the slot for a corrected reissue.
create unique index one_live_line_per_session
  on invoice_lines (session_id)
  where status <> 'voided';

create table xero_invoices (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references clients(id),
  xero_invoice_id text,                   -- null until created in Xero
  period          text not null,          -- e.g. '2026-06'
  status          text not null default 'draft',
  created_at      timestamptz not null default now()
);
```

### How cancel‑and‑rematch works without losing history

Two real situations, both fully preserved:

**(a) Same slot, different SP** (the SP drops out, client keeps the booking). The session row is untouched. We close the current assignment and open a new one — atomically:

```sql
begin;
  update session_assignments
     set status = 'superseded', ended_at = now(), reason = 'SP withdrew'
   where session_id = $1 and status = 'active';

  insert into session_assignments (session_id, provider_id, status)
  values ($1, $new_sp, 'active');
commit;
```

The partial unique index `one_active_assignment_per_session` guarantees that if two operators try to rematch the same session at once, exactly one succeeds — the other gets a unique‑violation and retries against the new state. The old SP's row stays forever as `superseded`: full audit trail.

**(b) Session cancelled and rebooked** (different time *and* SP). The original session is marked `cancelled` (its assignment moves to `cancelled`), and a brand‑new session is created with `supersedes_session_id` pointing back. Walking that chain reconstructs the entire history of reschedules for any slot.

Because invoice lines reference `assignment_id`, billing always follows the SP who actually delivered — a cancelled assignment never produces a line (only `delivered` sessions do, §3), so a dropped SP is never billed and the replacement is.

---

## 2. Consistency under concurrent writers

Three systems — the portal, n8n, and the Xero sync — can touch the same session at the same moment. Two distinct problems: (a) lost updates / illegal state transitions, and (b) duplicate side‑effects from retries. They need different tools.

### (a) Lost updates → optimistic concurrency on the state machine

Every status change on `sessions` is a compare‑and‑swap on `version`:

```sql
update sessions
   set status = 'delivered', version = version + 1, updated_at = now()
 where id = $1
   and version = $expected_version          -- the version the writer read
   and status = 'scheduled';                 -- legal transition guard
-- 0 rows updated  => someone else moved first; re-read and decide.
```

If n8n and the portal both try to mark the same session delivered, the second `UPDATE` matches zero rows and the caller knows to re‑read rather than blindly overwrite. The `status =` predicate doubles as a transition guard so we never go `cancelled → delivered`. For multi‑row critical sections (the rematch above), `SELECT … FOR UPDATE` on the session row serialises the operators pessimistically.

Run these mutations at `READ COMMITTED` (Postgres default) — the explicit predicates do the work, so we avoid the retry overhead of `SERIALIZABLE`. Reserve `SERIALIZABLE` for any path doing read‑then‑aggregate decisions across rows.

### (b) Retries → idempotency enforced by unique constraints

n8n *will* re‑run steps after timeouts and partial failures. The rule: **every automation write carries an idempotency key, and the database — not the workflow — rejects the duplicate.**

For invoice creation the idempotency key is simply the `session_id` (one delivered session = one line), backed by the partial unique index `one_live_line_per_session`. The create is written as an upsert that no‑ops on conflict:

```sql
insert into invoice_lines (session_id, assignment_id, amount_cents, currency, status)
select s.id, a.id, b.rate_cents, b.currency, 'pending'
  from sessions s
  join bookings b on b.id = s.booking_id
  join session_assignments a on a.session_id = s.id and a.status = 'active'
 where s.id = $1 and s.status = 'delivered'
on conflict (session_id) where status <> 'voided'
do nothing
returning id;
```

A retried n8n run returns zero rows instead of a second line. No coordination, no distributed lock — the unique index is the entire guarantee. The same pattern (a `unique` idempotency key + `ON CONFLICT DO NOTHING`) generalises to any automation insert.

### Why not let n8n call Xero directly?

Because that's a **dual write** — two systems (Postgres + Xero) updated outside a single transaction. If the DB commit succeeds but the Xero call times out (or vice‑versa) you get drift, and retries double‑bill. The fix is the transactional outbox in §3: n8n only ever writes to Postgres; a separate worker owns the Xero side.

---

## 3. Delivered session → Xero line, exactly once

### The transactional outbox

When a session is marked delivered, **one transaction** does three things: flip the session, create the (idempotent) invoice line, and drop an event in `sync_outbox`. Either all three commit or none do — no dual‑write window.

```sql
create table sync_outbox (
  id            bigint generated always as identity primary key,
  invoice_line_id uuid not null references invoice_lines(id),
  status        text not null default 'pending',  -- pending | done | failed
  attempts      integer not null default 0,
  -- The key we send to Xero so *it* dedupes server-side too. Deterministic.
  idempotency_key text not null unique,
  created_at    timestamptz not null default now()
);
```

```sql
-- Inside the same transaction that delivers + creates the line:
insert into sync_outbox (invoice_line_id, idempotency_key)
values ($line_id, 'invline:' || $line_id::text)
on conflict (idempotency_key) do nothing;
```

### The sync worker — the second line of defence

A single worker (or many, safely) drains the outbox using `FOR UPDATE SKIP LOCKED`, the Postgres idiom for a concurrent job queue — multiple workers never grab the same row:

```sql
select * from sync_outbox
 where status = 'pending'
 order by id
 for update skip locked
 limit 50;
```

For each row the worker:

1. **Short‑circuits if already done** — if `invoice_lines.xero_line_id IS NOT NULL`, mark the outbox row `done` and move on. This alone stops re‑pushes after a worker crash between "Xero succeeded" and "DB updated".
2. **Calls Xero with the deterministic idempotency key** (`invline:<id>`). Xero dedupes on its side, so even if step 1's guard is somehow bypassed, Xero itself returns the existing line rather than creating a second.
3. **On success, records `xero_line_id` + `xero_invoice_id`, sets the line `synced` and the outbox row `done`.** On failure, increments `attempts` for exponential‑backoff retry; past a threshold it goes to `failed` for a dead‑letter alert.

So duplication is blocked at **three** layers: the DB unique index (only one line can exist), the `xero_line_id` short‑circuit (don't re‑push), and Xero's own idempotency key (server‑side dedupe). A retry at any stage is a no‑op.

### Grouping into invoices

`xero_invoices` is the header (e.g. one draft per client per month). Lines attach to it; when the period closes the worker pushes the draft and finalises. Voiding a line (`status = 'voided'`) frees the partial‑unique slot so a corrected line can be reissued without fighting the constraint — clean handling of adjustments.

---

## 4. Zero‑downtime migration (expand / contract)

Use the **parallel‑change** pattern: add the new world alongside the old, move traffic gradually, retire the old world last. Every DDL step below is non‑blocking.

**Phase 1 — Expand (additive, no downtime).** Create the new tables and any new columns as *nullable* (or with Postgres 11+ fast defaults, which don't rewrite the table). Build indexes with `CREATE INDEX CONCURRENTLY` so writes aren't blocked. Add foreign keys as `NOT VALID` first, then `VALIDATE CONSTRAINT` in a separate step (validation takes only a `SHARE UPDATE EXCLUSIVE` lock, not a full table lock). Set a `lock_timeout` so any migration that *would* block bails out instead of queuing behind it.

```sql
alter table invoice_lines
  add constraint fk_line_assignment
  foreign key (assignment_id) references session_assignments(id)
  not valid;                       -- instant, no full-table scan

alter table invoice_lines validate constraint fk_line_assignment;  -- non-blocking
```

**Phase 2 — Dual‑write.** Deploy app code that writes to *both* the old structure and the new tables. Reads still come from the old structure. Nothing user‑facing changes.

**Phase 3 — Backfill in batches.** Migrate historical sessions/SP‑assignments/invoices into the new model in small, idempotent batches (keyed on source id with `ON CONFLICT DO NOTHING`) to keep transactions short and avoid long locks. Re‑runnable safely if interrupted.

**Phase 4 — Verify parity.** Shadow‑read from the new model and diff against the old in the background; reconcile until the counts match (especially invoice totals — this is money).

**Phase 5 — Flip reads.** Behind a feature flag, switch reads to the new model, one slice of traffic at a time. Roll back instantly by toggling the flag if anything looks off.

**Phase 6 — Contract.** Once the new model has served all reads cleanly for a bake‑in period, stop dual‑writing and drop the old columns/tables in a later release.

On Supabase specifically: manage every step as a versioned migration, keep RLS policies on the new tables from day one (the portal reads through RLS, so the policies must exist *before* reads flip), and run backfills as a background worker or scheduled function rather than one giant statement.

---

## Summary of guarantees

| Requirement | Mechanism |
|---|---|
| Never lose cancel/rematch history | Append‑only `session_assignments` + `supersedes_session_id` chain; nothing overwritten |
| One SP responsible at a time | Partial unique index `one_active_assignment_per_session` |
| Concurrent writers don't clobber | Optimistic `version` CAS + transition guards; `FOR UPDATE` for multi‑row critical sections |
| Retried automation can't duplicate | Idempotency key + partial unique index + `ON CONFLICT DO NOTHING` |
| No dual‑write drift to Xero | Transactional outbox; n8n writes only Postgres |
| Exactly‑once invoice line | DB unique index + `xero_line_id` short‑circuit + Xero idempotency key (three layers) |
| No double‑bill on retry | Same three layers; voided lines free the slot for corrections |
| No downtime migration | Expand/contract: additive DDL, `CONCURRENTLY`, `NOT VALID`→`VALIDATE`, dual‑write, batched backfill, flagged cutover |
