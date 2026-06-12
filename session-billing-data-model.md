# Database Design — Recurring Sessions to Xero

How I'd build this on Postgres / Supabase — the schema, how a cancel-and-rematch keeps the delivery history, how I'd stop the portal, n8n and the Xero sync from stepping on each other, and how I'd roll it out with no downtime.

Before the schema, the two calls everything else falls out of:

- I don't store **the current provider** on the session. The second you do that, a rematch overwrites it and you've lost who delivered. So delivery gets its own table.
- I don't trust the portal, n8n and the Xero sync to each be careful on their own. Three independent writers will race eventually, so I'd rather push the real guarantees down into Postgres than coordinate them in app code.

---

## Part 1 — The data model

### How I'm modelling it

A session is just a slot in time and never changes. Who's on the hook to deliver it lives in a separate `session_assignments` table, one row per provider that's ever held that slot. A cancel-and-rematch doesn't touch a "provider" column anywhere; it closes the old assignment and opens a new one. That way the history isn't something I have to remember to log — it's just the rows sitting there.

| Table | What it's for | PK | Key FKs |
|---|---|---|---|
| `clients` | The people booking sessions | `client_id` | — |
| `service_providers` | Who delivers the sessions | `sp_id` | — |
| `engagements` | A recurring arrangement (the series) | `engagement_id` | `client_id` |
| `sessions` | A single scheduled slot, never edited | `session_id` | `engagement_id`, `client_id` |
| `session_assignments` | Every provider that held a slot | `assignment_id` | `session_id`, `sp_id`, `superseded_by` |
| `xero_invoices` | Groups lines into one Xero invoice | `xero_invoice_pk` | `client_id` |
| `invoice_lines` | One per delivered slot, syncs to Xero | `invoice_line_id` | `assignment_id` (UQ), `xero_invoice_pk` |

### The tables

Parties, the recurring engagement, and the session slot itself:

```sql
create table clients (
  client_id   uuid primary key default gen_random_uuid(),
  full_name   text not null,
  email       text unique,
  created_at  timestamptz not null default now()
);

create table service_providers (
  sp_id           uuid primary key default gen_random_uuid(),
  full_name       text not null,
  status          text not null default 'active',
  xero_contact_id text,                 -- their identity in Xero
  created_at      timestamptz not null default now()
);

create table engagements (              -- the recurring arrangement (series)
  engagement_id uuid primary key default gen_random_uuid(),
  client_id     uuid not null references clients,
  service_type  text not null,
  rrule         text,                   -- iCal RRULE for the recurrence
  rate_cents    int  not null,          -- price per session, copied at delivery
  currency      char(3) not null default 'AUD',
  status        text not null default 'active',
  created_at    timestamptz not null default now()
);

create table sessions (                 -- one slot in time, never edited
  session_id      uuid primary key default gen_random_uuid(),
  engagement_id   uuid not null references engagements,
  client_id       uuid not null references clients,
  sequence_no     int  not null,        -- nth session in the series
  scheduled_start timestamptz not null,
  scheduled_end   timestamptz not null,
  status          text not null default 'scheduled',
  version         int  not null default 0,   -- used for the locking in part 2
  created_at      timestamptz not null default now(),
  unique (engagement_id, sequence_no)
);
```

The assignments table is where the history actually lives. The one thing I really care about is that only one assignment is live at a time, and I'd rather the database enforce that than hope the app does, so there's a partial unique index at the bottom:

```sql
create table session_assignments (      -- every provider that held the slot
  assignment_id uuid primary key default gen_random_uuid(),
  session_id    uuid not null references sessions,
  sp_id         uuid not null references service_providers,
  status        text not null default 'assigned',
    -- assigned | delivered | no_show | cancelled | rematched
  is_active     boolean not null default true,
  assigned_at   timestamptz not null default now(),
  delivered_at  timestamptz,
  cancel_reason text,
  superseded_by uuid references session_assignments,  -- old row -> replacement
  version       int  not null default 0,
  created_at    timestamptz not null default now()
);

-- only one live assignment per session, enforced by the DB
create unique index one_active_assignment_per_session
  on session_assignments (session_id) where is_active;
```

Invoices hang off the delivered assignment, not the session — so I always bill the provider who actually showed up. Lines sit under a `xero_invoices` header so a client gets one invoice per period rather than one per session. The unique on `assignment_id` is doing real work; I'll come back to it in part 2:

```sql
create table xero_invoices (            -- groups lines into one Xero invoice
  xero_invoice_pk uuid primary key default gen_random_uuid(),
  client_id       uuid not null references clients,
  period          text not null,        -- e.g. '2026-06'
  xero_invoice_id text,                 -- null until created in Xero
  status          text not null default 'draft',
  created_at      timestamptz not null default now()
);

create table invoice_lines (            -- one per delivered assignment
  invoice_line_id uuid primary key default gen_random_uuid(),
  assignment_id   uuid not null unique references session_assignments,
  client_id       uuid not null references clients,
  sp_id           uuid not null references service_providers,
  xero_invoice_pk uuid references xero_invoices,
  amount_cents    int  not null,        -- copied from engagement at delivery
  currency        char(3) not null default 'AUD',
  sync_status     text not null default 'pending',  -- pending | synced | failed
  xero_line_id    text,
  synced_at       timestamptz,
  created_at      timestamptz not null default now()
);
```

### Why this keeps the history

A cancelled assignment never produces an invoice, only a delivered one does, so "who delivered what" is just `select * from session_assignments where status = 'delivered'`. When SP A gets dropped and SP B takes over, A's row doesn't go anywhere: it ends as `rematched` with `superseded_by` pointing at B's new row, so I can walk the whole chain for any slot. And because of the index there's physically no way to end up with two live providers on one session, even if some n8n flow does something silly.

### Cancel-and-rematch, in one transaction

```sql
begin;
  select 1 from sessions where session_id = $sid for update;  -- block a 2nd rematch

  update session_assignments
     set status = 'rematched', is_active = false,
         cancel_reason = $reason, version = version + 1
   where session_id = $sid and is_active and status = 'assigned';

  insert into session_assignments (session_id, sp_id, status, is_active)
  values ($sid, $new_sp, 'assigned', true);
commit;
```

The `status = 'assigned'` check stops me rematching something that was already delivered, and the row lock plus that unique index mean two rematches firing at the same time can't both win. One of them just hits a unique violation and retries.

---

## Part 2 — Keeping three writers off each other's toes

Three things write to the same session: the portal, the n8n flows, and whatever's pushing to Xero. I need two properties out of this — concurrent edits shouldn't clobber each other, and a retried automation shouldn't create duplicates or bill twice. I lean on the database for all of it rather than try to coordinate the writers.

### 1. Unique constraints, so retries are basically free

`invoice_lines.assignment_id` is unique, so a delivered session can only ever have one invoice line. If n8n runs the create step twice (and it will, eventually), the second one is a no-op:

```sql
insert into invoice_lines (assignment_id, client_id, sp_id, amount_cents)
values ($aid, $cid, $sp, $amt)
on conflict (assignment_id) do nothing;   -- a retry just does nothing
```

This is the main thing stopping a double-bill, and it doesn't rely on the automation being well written.

### 2. Idempotency keys for the multi-step stuff

Each n8n run carries a key, something like `hash(session_id + 'deliver' + run_id)`, written into a `processed_events` table in the same transaction as the work it's doing. Replay the workflow and it collides on the key and bails out. The constraint above stops a duplicate row; the key stops a duplicate run from getting halfway through.

### 3. A version column so edits don't get lost

For the case where the portal and an n8n flow both edit the same session: every editable row has a `version`, and updates are conditional on it. Zero rows changed means someone got there first, so I re-read and decide again. No long-held locks, no silently lost write:

```sql
update sessions set status = 'cancelled', version = version + 1
 where session_id = $sid and version = $expected;  -- 0 rows = someone beat me
```

### 4. Read-committed is enough

The Supabase default (READ COMMITTED) plus the explicit locks above covers all of this. The only place I'd reach for SERIALIZABLE is the rematch transaction, with a retry on a 40001 — it's rare, and it's the one spot where getting it wrong actually hurts.

---

## Part 3 — Delivered session to Xero, without ever double-billing

This is the part I'd be most careful about, because n8n will retry and money is the thing you can't get wrong. The rule I follow: nothing calls the Xero API inline. Delivering a session and creating the (pending) invoice line happen in one transaction; a separate worker drains the queue and talks to Xero. That avoids the dual-write trap where the DB commits but the Xero call times out and a retry bills again.

A single worker — or a few — picks up pending lines with `for update skip locked`, so I can scale the workers out and none of them grab the same row:

```sql
update invoice_lines set sync_status = 'syncing'
 where invoice_line_id = (
   select invoice_line_id from invoice_lines
    where sync_status = 'pending'
    order by created_at
    for update skip locked      -- run a few workers, none grab the same row
    limit 1)
returning *;
```

Before it POSTs anything it checks whether this line already has a Xero id. Null means create it and store the id back; not-null means this is a retry, so skip the create and just reconcile. So a double-bill has to get past **three** independent things: the unique constraint (only one line can exist per delivered assignment), the id check (don't re-create what's already there), and Xero's own idempotency key. And if Xero is down, the rows just sit `pending` until it's back — nothing's lost.

Lines attach to a `xero_invoices` header so they bill as one invoice per client per period; when the period closes the worker pushes the draft and finalises it. A correction is a void on the line (which frees the unique slot) plus a fresh line, synced to Xero as an adjustment — never an in-place edit of something Xero already issued.

---

## Part 4 — Rolling it out with no downtime

I'd do this as an expand/contract migration — stand the new model up alongside the old one, move traffic across gradually, and only retire the old shape at the very end. Every step is reversible and nothing takes a blocking lock.

**Expand.** Create the new tables and any new columns as nullable, build indexes with `CREATE INDEX CONCURRENTLY`, and add foreign keys as `NOT VALID` first, then `VALIDATE` in a separate step so they never take a full-table lock. I'd set a `lock_timeout` so a migration that would block just bails instead of queuing behind live traffic:

```sql
alter table invoice_lines
  add constraint fk_line_assignment
  foreign key (assignment_id) references session_assignments
  not valid;                         -- instant, no full-table scan

alter table invoice_lines validate constraint fk_line_assignment;  -- non-blocking
```

**Dual-write.** Ship app code that writes to both the old structure and the new tables. Reads still come from the old one, so nothing user-facing changes yet.

**Backfill.** Move the history across in small idempotent batches keyed on the source id (`on conflict do nothing`), so it's safe to stop and restart and never holds a long lock.

**Verify.** Shadow-read from the new model and diff it against the old in the background — and I'd be strict reconciling invoice totals, because that's money.

**Cut over.** Flip reads to the new model behind a feature flag, one slice of traffic at a time, with instant rollback if anything looks off.

**Contract.** Once it's served all reads cleanly for a bake-in period, stop dual-writing and drop the old columns and tables in a later release.

On Supabase specifically: I'd keep every step as a versioned migration, and make sure RLS policies exist on the new tables before any read flips to them, since the portal reads through RLS.

---

## A few assumptions

The brief's a compressed version of the real thing, so to be explicit about what I assumed:

- Price lives on the engagement and gets copied onto the invoice line at delivery time, so a later re-rate doesn't rewrite old invoices.
- Once Xero has issued an invoice number it owns it. I store the id and never re-create.
- One delivered session is one invoice line. Partial delivery or multi-currency would add columns to `invoice_lines` but wouldn't change the shape of the model.

Happy to talk through any of it, or go deeper on the concurrency or migration side if that's the part you care most about.
