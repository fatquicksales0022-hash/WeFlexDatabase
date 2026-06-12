-- Walkthrough: two delivered sessions batched into ONE monthly Xero invoice,
-- with a cancel-and-rematch in between. Mirrors the README story (Maria).
--
-- Run after schema.sql:
--   psql "$DATABASE_URL" -f schema.sql -f examples/walkthrough.sql
--
-- Fixed UUIDs are used so the steps are easy to follow.

begin;

-- People --------------------------------------------------------------------
insert into clients (client_id, full_name, email) values
  ('11111111-1111-1111-1111-111111111111', 'Maria Diaz', 'maria@example.com');

insert into service_providers (sp_id, full_name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Alex'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Bea');

-- 1-2. Engagement + two weekly slots in the same month ----------------------
insert into engagements (engagement_id, client_id, service_type, rrule, rate_cents) values
  ('22222222-2222-2222-2222-222222222222',
   '11111111-1111-1111-1111-111111111111', 'coaching', 'FREQ=WEEKLY;BYDAY=TU', 12000);

insert into sessions (session_id, engagement_id, client_id, sequence_no, scheduled_start, scheduled_end) values
  ('33333333-3333-3333-3333-333333333331', '22222222-2222-2222-2222-222222222222',
   '11111111-1111-1111-1111-111111111111', 1, '2026-06-02 10:00+00', '2026-06-02 11:00+00'),
  ('33333333-3333-3333-3333-333333333332', '22222222-2222-2222-2222-222222222222',
   '11111111-1111-1111-1111-111111111111', 2, '2026-06-09 10:00+00', '2026-06-09 11:00+00');

-- 3-4. Slot #1 -> Alex, delivered, billed -----------------------------------
insert into session_assignments (assignment_id, session_id, sp_id, status, is_active, delivered_at) values
  ('44444444-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333331',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'delivered', true, now());
update sessions set status = 'completed' where session_id = '33333333-3333-3333-3333-333333333331';

-- open June invoice, add a line, queue a sync job (idempotent throughout)
insert into xero_invoices (client_id, period_month) values
  ('11111111-1111-1111-1111-111111111111', '2026-06-01')
on conflict (client_id, period_month) do nothing;

insert into invoice_lines (assignment_id, xero_invoice_id, client_id, sp_id, amount_cents)
select '44444444-0000-0000-0000-000000000001', xi.xero_invoice_id,
       '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 12000
  from xero_invoices xi
 where xi.client_id = '11111111-1111-1111-1111-111111111111' and xi.period_month = '2026-06-01'
on conflict (assignment_id) where status = 'issued' do nothing;

insert into sync_outbox (aggregate, aggregate_id, op, idempotency_key)
select 'xero_invoice', xi.xero_invoice_id,
       case when xi.xero_id is null then 'create' else 'update' end,
       'inv:' || xi.xero_invoice_id || ':44444444-0000-0000-0000-000000000001'
  from xero_invoices xi
 where xi.client_id = '11111111-1111-1111-1111-111111111111' and xi.period_month = '2026-06-01'
on conflict (idempotency_key) do nothing;

-- 5. Slot #2 -> Alex, then rematched to Bea ---------------------------------
-- (deactivate the old row BEFORE activating the new one, to satisfy the
--  one-active-per-session unique index)
insert into session_assignments (assignment_id, session_id, sp_id, status, is_active) values
  ('44444444-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333332',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'assigned', true);

update session_assignments
   set status = 'rematched', is_active = false,
       cancel_reason = 'provider unavailable', version = version + 1
 where assignment_id = '44444444-0000-0000-0000-000000000002';

insert into session_assignments (assignment_id, session_id, sp_id, status, is_active) values
  ('44444444-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333332',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'assigned', true);

update session_assignments set superseded_by = '44444444-0000-0000-0000-000000000003'
 where assignment_id = '44444444-0000-0000-0000-000000000002';

-- 6. Bea delivers #2 -> a SECOND line on the SAME June invoice (batched) -----
update session_assignments
   set status = 'delivered', delivered_at = now(), version = version + 1
 where assignment_id = '44444444-0000-0000-0000-000000000003';
update sessions set status = 'completed' where session_id = '33333333-3333-3333-3333-333333333332';

insert into xero_invoices (client_id, period_month) values
  ('11111111-1111-1111-1111-111111111111', '2026-06-01')
on conflict (client_id, period_month) do nothing;

insert into invoice_lines (assignment_id, xero_invoice_id, client_id, sp_id, amount_cents)
select '44444444-0000-0000-0000-000000000003', xi.xero_invoice_id,
       '11111111-1111-1111-1111-111111111111', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 12000
  from xero_invoices xi
 where xi.client_id = '11111111-1111-1111-1111-111111111111' and xi.period_month = '2026-06-01'
on conflict (assignment_id) where status = 'issued' do nothing;

insert into sync_outbox (aggregate, aggregate_id, op, idempotency_key)
select 'xero_invoice', xi.xero_invoice_id,
       case when xi.xero_id is null then 'create' else 'update' end,
       'inv:' || xi.xero_invoice_id || ':44444444-0000-0000-0000-000000000003'
  from xero_invoices xi
 where xi.client_id = '11111111-1111-1111-1111-111111111111' and xi.period_month = '2026-06-01'
on conflict (idempotency_key) do nothing;

commit;

-- 7. What the data says -----------------------------------------------------

-- who delivered what (expect: #1 Alex, #2 Bea)
select sequence_no, provider_name, delivered_at
from delivered_sessions
where client_id = '11111111-1111-1111-1111-111111111111'
order by sequence_no;

-- the trail for slot #2 (Alex -> Bea, nothing lost)
select sp_id, status, is_active, superseded_by, created_at
from session_assignments
where session_id = '33333333-3333-3333-3333-333333333332'
order by created_at;

-- one invoice for the month, two lines on it (batched)
select xi.period_month,
       count(il.invoice_line_id) as lines,
       sum(il.amount_cents)      as total_cents
from xero_invoices xi
join invoice_lines il on il.xero_invoice_id = xi.xero_invoice_id
where xi.client_id = '11111111-1111-1111-1111-111111111111'
group by xi.period_month;
