-- Run once in the Supabase SQL Editor (safe to run again).
-- Lets a store login record and undo invoices for its own store, and mark order lines as received.

-- Manual adjustments for HQ and store logins. Safe to run more than once.
-- 1. A store (or HQ) can mark cases on an open line as received, in full or in part.
create or replace function public.receive_line(p_line bigint, p_cases int) returns void
language plpgsql security definer set search_path = public as $$
declare l record;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  if p_cases is null or p_cases < 1 then raise exception 'Cases received must be at least 1.'; end if;
  select ol.id, ol.order_id, ol.code, ol.cases, ol.price, ol.status, ol.filled, ol.released_at, o.store_id into l
    from public.order_lines ol join public.orders o on o.id = ol.order_id
   where ol.id = p_line for update of ol;
  if not found then raise exception 'That line no longer exists.'; end if;
  if not (public.is_hq() or l.store_id = public.my_store()) then raise exception 'Not allowed.'; end if;
  if l.status not in ('pending','production','ready') then raise exception 'That line has already been delivered or cancelled.'; end if;
  if p_cases > l.cases then raise exception 'That is more than the % cases on this line.', l.cases; end if;
  if p_cases = l.cases then
    update public.order_lines set status = 'done', filled = cases where id = l.id;
  else
    update public.order_lines set cases = l.cases - p_cases, filled = least(l.filled, l.cases - p_cases) where id = l.id;
    insert into public.order_lines (order_id, code, cases, price, status, filled, released_at)
      values (l.order_id, l.code, p_cases, l.price, 'done', p_cases, l.released_at);
  end if;
end $$;
revoke all on function public.receive_line(bigint, int) from public, anon;
grant execute on function public.receive_line(bigint, int) to authenticated;

-- 2. Stores may record and undo invoices for their own store (HQ can still do any store).
create or replace function public.apply_invoice(p_invoice text, p_store text, p_date date, p_lines jsonb, p_kind text default 'invoice') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; l record; remaining int; t int; changes jsonb := '[]'::jsonb; extra jsonb := '[]'::jsonb;
  matched int := 0; newid bigint; inv uuid; unknown jsonb := '[]'::jsonb; free jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not (public.is_hq() or (public.my_store() is not null and p_store = public.my_store())) then raise exception 'You can only record invoices for your own store.'; end if;
  if p_kind not in ('invoice','credit') then raise exception 'Choose invoice or credit note.'; end if;
  if coalesce(trim(p_invoice), '') = '' then raise exception 'Enter the invoice number.'; end if;
  if not exists (select 1 from public.stores where id = p_store) then raise exception 'Choose a store.'; end if;
  if exists (select 1 from public.invoices where invoice_no = trim(p_invoice) and reversed_at is null) then
    raise exception 'Document % has already been recorded. Undo it first if it was wrong.', trim(p_invoice);
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'The invoice has no lines.'; end if;

  for r in
    select upper(trim(x->>'code')) as code, sum((x->>'cases')::numeric)::int as cases
      from jsonb_array_elements(p_lines) x
     where coalesce(trim(x->>'code'), '') <> '' and (x->>'cases')::numeric > 0
       and not (coalesce(x->>'price', '') <> '' and (x->>'price')::numeric = 0)
     group by 1 order by 1
  loop
    if not exists (select 1 from public.products where upper(code) = r.code) then
      unknown := unknown || jsonb_build_object('code', r.code, 'cases', r.cases);
    end if;
    remaining := r.cases;
    for l in
      select ol.id, ol.cases, ol.status, ol.filled, ol.price, ol.order_id, ol.released_at
        from public.order_lines ol join public.orders o on o.id = ol.order_id
       where o.store_id = p_store and upper(ol.code) = r.code and ol.status in ('ready','production','pending')
       order by case ol.status when 'ready' then 0 when 'production' then 1 else 2 end, o.created_at, ol.id
       for update of ol
    loop
      exit when remaining <= 0;
      t := least(l.cases, remaining);
      if t = l.cases then
        update public.order_lines set status = case when p_kind = 'credit' then 'cancelled' else 'done' end, filled = case when p_kind = 'credit' then filled else cases end where id = l.id;
        changes := changes || jsonb_build_object('op','u','id',l.id,'status',l.status,'cases',l.cases,'filled',l.filled,'new_status',case when p_kind = 'credit' then 'cancelled' else 'done' end,'new_cases',l.cases);
      else
        update public.order_lines set cases = l.cases - t, filled = least(l.filled, l.cases - t) where id = l.id;
        insert into public.order_lines (order_id, code, cases, price, status, filled, released_at)
          values (l.order_id, (select code from public.order_lines where id = l.id), t, l.price, case when p_kind = 'credit' then 'cancelled' else 'done' end, case when p_kind = 'credit' then 0 else t end, l.released_at) returning id into newid;
        changes := changes || jsonb_build_object('op','u','id',l.id,'status',l.status,'cases',l.cases,'filled',l.filled,'new_status',l.status,'new_cases',l.cases - t)
                           || jsonb_build_object('op','i','id',newid);
      end if;
      remaining := remaining - t; matched := matched + t;
    end loop;
    if remaining > 0 then extra := extra || jsonb_build_object('code', r.code, 'cases', remaining); end if;
  end loop;

  -- zero-price lines are free samples: recorded, but never matched to orders
  select coalesce(jsonb_agg(jsonb_build_object('code', c, 'cases', n)), '[]'::jsonb) into free from (
    select upper(trim(x->>'code')) as c, sum((x->>'cases')::numeric)::int as n
      from jsonb_array_elements(p_lines) x
     where coalesce(trim(x->>'code'), '') <> '' and (x->>'cases')::numeric > 0
       and coalesce(x->>'price', '') <> '' and (x->>'price')::numeric = 0
     group by 1) f;
  insert into public.invoices (invoice_no, store_id, inv_date, lines, result, changes, kind)
    values (trim(p_invoice), p_store, p_date, p_lines,
            jsonb_build_object('matched', matched, 'extra', extra, 'unknown', unknown, 'free', free), changes, p_kind)
    returning id into inv;
  return jsonb_build_object('id', inv, 'matched', matched, 'extra', extra, 'unknown', unknown, 'free', free);
end $$;

create or replace function public.undo_invoice(p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare inv record; c jsonb; i int;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select * into inv from public.invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if not (public.is_hq() or coalesce(inv.store_id = public.my_store(), false)) then raise exception 'Not allowed.'; end if;
  if inv.reversed_at is not null then raise exception 'That invoice was already undone.'; end if;
  for i in reverse (jsonb_array_length(inv.changes) - 1) .. 0 loop
    c := inv.changes -> i;
    if c->>'op' = 'u' and not exists (select 1 from public.order_lines where id = (c->>'id')::bigint and status = c->>'new_status' and cases = (c->>'new_cases')::int) then
      raise exception 'Some orders have changed since this invoice was recorded, so it cannot be undone automatically.';
    end if;
  end loop;
  for i in reverse (jsonb_array_length(inv.changes) - 1) .. 0 loop
    c := inv.changes -> i;
    if c->>'op' = 'i' then delete from public.order_lines where id = (c->>'id')::bigint;
    else update public.order_lines set status = c->>'status', cases = (c->>'cases')::int, filled = (c->>'filled')::int where id = (c->>'id')::bigint;
    end if;
  end loop;
  update public.invoices set reversed_at = now() where id = p_invoice;
end $$;
