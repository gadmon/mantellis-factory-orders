-- Mantellis Factory Orders: database schema for Supabase
-- Run this whole file once in the Supabase SQL editor (Dashboard > SQL Editor > New query > paste > Run).
-- Safe to read first. It creates tables, row-level security, three helper functions and the starting data.

create table if not exists public.stores (
  id text primary key,
  name text not null,
  region text not null default '',
  active boolean not null default true
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'store' check (role in ('hq','store')),
  store_id text references public.stores(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb
);

create table if not exists public.products (
  code text primary key,
  name text not null,
  lists text[] not null default '{}',
  category text,
  pack text,
  per_case text,
  case_price numeric(12,2) not null,
  unit_price numeric(12,4),
  rrp numeric(12,2),
  barcode text,
  kind text not null default 'bake' check (kind in ('bake','supply')),
  par int check (par is null or par > 0),
  active boolean not null default true
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  store_id text not null references public.stores(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  method text not null check (method in ('collect','deliver')),
  need_by date,
  notes text not null default '',
  pallet_kg numeric(10,2),
  delivery_cost numeric(12,2)
);

create table if not exists public.order_lines (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  code text not null references public.products(code),
  cases int not null check (cases > 0),
  price numeric(12,2) not null,
  status text not null default 'pending' check (status in ('pending','production','ready','done','cancelled')),
  released_at timestamptz,
  filled int not null default 0,
  check (filled >= 0 and filled <= cases)
);
create index if not exists order_lines_order_idx on public.order_lines(order_id);
create index if not exists order_lines_code_status_idx on public.order_lines(code, status);

create table if not exists public.history (
  id bigint generated always as identity primary key,
  order_date date not null,
  store_id text not null,
  code text not null,
  cases int not null check (cases > 0)
);

-- ---------- who is who ----------
create or replace function public.is_hq() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'hq');
$$;

create or replace function public.my_store() returns text
language sql stable security definer set search_path = public as $$
  select store_id from public.profiles where id = auth.uid();
$$;

-- a signed-in person who is HQ or linked to a store; anyone else (for example a stray sign-up) sees nothing
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and (role = 'hq' or store_id is not null));
$$;

-- every new login gets a profile; HQ then links it to a store in the app (Setup > Logins)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- row-level security ----------
alter table public.stores      enable row level security;
alter table public.profiles    enable row level security;
alter table public.settings    enable row level security;
alter table public.products    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_lines enable row level security;
alter table public.history     enable row level security;

drop policy if exists stores_read    on public.stores;
drop policy if exists stores_hq      on public.stores;
drop policy if exists settings_read  on public.settings;
drop policy if exists settings_hq    on public.settings;
drop policy if exists products_read  on public.products;
drop policy if exists products_hq    on public.products;
drop policy if exists profiles_read  on public.profiles;
drop policy if exists profiles_hq    on public.profiles;
drop policy if exists orders_read    on public.orders;
drop policy if exists orders_hq      on public.orders;
drop policy if exists lines_read     on public.order_lines;
drop policy if exists lines_hq       on public.order_lines;
drop policy if exists history_hq     on public.history;

create policy stores_read   on public.stores   for select to authenticated using (public.is_member());
create policy stores_hq     on public.stores   for all    to authenticated using (public.is_hq()) with check (public.is_hq());
create policy settings_read on public.settings for select to authenticated using (public.is_member());
create policy settings_hq   on public.settings for all    to authenticated using (public.is_hq()) with check (public.is_hq());
create policy products_read on public.products for select to authenticated using (public.is_member());
create policy products_hq   on public.products for all    to authenticated using (public.is_hq()) with check (public.is_hq());

-- a person reads their own profile; HQ reads and edits all of them
create policy profiles_read on public.profiles for select to authenticated using (id = auth.uid() or public.is_hq());
create policy profiles_hq   on public.profiles for all    to authenticated using (public.is_hq()) with check (public.is_hq());

-- stores see only their own store's orders; HQ sees all. Stores place orders through place_order() below.
create policy orders_read   on public.orders for select to authenticated using (public.is_hq() or store_id = public.my_store());
create policy orders_hq     on public.orders for all    to authenticated using (public.is_hq()) with check (public.is_hq());
create policy lines_read    on public.order_lines for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_lines.order_id));
create policy lines_hq      on public.order_lines for all to authenticated using (public.is_hq()) with check (public.is_hq());

create policy history_hq    on public.history for all to authenticated using (public.is_hq()) with check (public.is_hq());

-- nothing is readable without signing in
revoke all on all tables in schema public from anon;

-- ---------- order functions (the only way a store changes anything) ----------
create or replace function public.place_order(p_store text, p_method text, p_need_by date, p_notes text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_store text; v_id uuid; d jsonb; l jsonb; pr public.products;
  v_today date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  if not public.is_member() then raise exception 'Your login is not linked to a store yet. Ask HQ.'; end if;
  if public.is_hq() then v_store := coalesce(p_store, public.my_store()); else v_store := public.my_store(); end if;
  if v_store is null or not exists (select 1 from public.stores where id = v_store) then
    raise exception 'Choose a store to order for.';
  end if;
  if p_method not in ('collect','deliver') then raise exception 'Choose collect or deliver.'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one product.';
  end if;
  select data into d from public.settings where id = 1;
  if not public.is_hq() and d is not null and coalesce(d->>'recordOnly','') <> 'true'
     and coalesce(d->>'closeFrom','') <> '' and coalesce(d->>'reopen','') <> ''
     and v_today >= (d->>'closeFrom')::date and v_today < (d->>'reopen')::date then
    raise exception 'The factory is closed to new orders until %.', to_char((d->>'reopen')::date, 'DD Mon YYYY');
  end if;
  insert into public.orders (store_id, created_by, method, need_by, notes)
    values (v_store, auth.uid(), p_method, p_need_by, left(coalesce(p_notes,''), 1000))
    returning id into v_id;
  for l in select * from jsonb_array_elements(p_lines) loop
    select * into pr from public.products where code = (l->>'code') and active;
    if not found then raise exception 'Unknown product %.', l->>'code'; end if;
    if coalesce((l->>'cases')::int, 0) < 1 then raise exception 'Cases for % must be at least 1.', pr.code; end if;
    insert into public.order_lines (order_id, code, cases, price) values (v_id, pr.code, (l->>'cases')::int, pr.case_price);
  end loop;
  return v_id;
end $$;

create or replace function public.cancel_line(p_line bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  update public.order_lines l set status = 'cancelled'
    from public.orders o
   where l.id = p_line and o.id = l.order_id and l.status = 'pending'
     and (public.is_hq() or o.store_id = public.my_store());
  if not found then raise exception 'That line can no longer be cancelled.'; end if;
end $$;

-- Remove a whole order entered by mistake. A store can do this only while nothing in it has started production; HQ can always.
create or replace function public.delete_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s text;
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  select store_id into s from public.orders where id = p_order;
  if not found then raise exception 'That order no longer exists.'; end if;
  if not (public.is_hq() or s = public.my_store()) then raise exception 'Not allowed.'; end if;
  if not public.is_hq() and exists (select 1 from public.order_lines where order_id = p_order and status not in ('pending','cancelled')) then
    raise exception 'The factory has already started part of this order. Ask HQ to remove it.';
  end if;
  delete from public.orders where id = p_order;
end $$;

-- ---------- factory invoices: record what was delivered and clear it from outstanding ----------
create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_no text not null,
  store_id text not null references public.stores(id),
  inv_date date,
  uploaded_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  lines jsonb not null,
  result jsonb not null default '{}'::jsonb,
  changes jsonb not null default '[]'::jsonb,
  reversed_at timestamptz
);
alter table public.invoices add column if not exists kind text not null default 'invoice';
create unique index if not exists invoices_live_no on public.invoices (invoice_no) where reversed_at is null;
alter table public.invoices enable row level security;
drop policy if exists invoices_hq on public.invoices;
drop policy if exists invoices_read on public.invoices;
create policy invoices_hq   on public.invoices for all    to authenticated using (public.is_hq()) with check (public.is_hq());
create policy invoices_read on public.invoices for select to authenticated using (store_id = public.my_store());

-- HQ only. p_lines = [{"code":"M810","cases":5}, ...]. Delivered cases clear that store's oldest outstanding lines
-- (ready first, then in production, then waiting). Anything left over is reported, never guessed.
drop function if exists public.apply_invoice(text, text, date, jsonb);
create or replace function public.apply_invoice(p_invoice text, p_store text, p_date date, p_lines jsonb, p_kind text default 'invoice') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r record; l record; remaining int; t int; changes jsonb := '[]'::jsonb; extra jsonb := '[]'::jsonb;
  matched int := 0; newid bigint; inv uuid; unknown jsonb := '[]'::jsonb; free jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not public.is_hq() then raise exception 'Only HQ can record invoices.'; end if;
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

-- HQ only. Puts every order line back exactly as it was before the invoice was applied.
create or replace function public.undo_invoice(p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare inv record; c jsonb; i int;
begin
  if auth.uid() is null or not public.is_hq() then raise exception 'Only HQ can undo invoices.'; end if;
  select * into inv from public.invoices where id = p_invoice for update;
  if not found then raise exception 'Invoice not found.'; end if;
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

-- Totals only: cases waiting per product and how many stores are waiting. No store names, no order details.
create or replace function public.get_board() returns table (code text, cases bigint, stores bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'Not allowed.'; end if;
  return query
    select l.code, sum(l.cases)::bigint, count(distinct o.store_id)::bigint
      from public.order_lines l join public.orders o on o.id = l.order_id
     where l.status = 'pending' group by l.code;
end $$;

revoke all on function public.place_order(text, text, date, text, jsonb) from public, anon;
revoke all on function public.cancel_line(bigint) from public, anon;
revoke all on function public.undo_invoice(uuid) from public, anon;
revoke all on function public.apply_invoice(text, text, date, jsonb, text) from public, anon;
revoke all on function public.delete_order(uuid) from public, anon;
revoke all on function public.get_board() from public, anon;
revoke all on function public.is_hq() from public, anon;
revoke all on function public.my_store() from public, anon;
revoke all on function public.is_member() from public, anon;
grant execute on function public.place_order(text, text, date, text, jsonb) to authenticated;
grant execute on function public.cancel_line(bigint) to authenticated;
grant execute on function public.undo_invoice(uuid) to authenticated;
grant execute on function public.apply_invoice(text, text, date, jsonb, text) to authenticated;
grant execute on function public.delete_order(uuid) to authenticated;
grant execute on function public.get_board() to authenticated;
grant execute on function public.is_hq() to authenticated;
grant execute on function public.my_store() to authenticated;
grant execute on function public.is_member() to authenticated;

-- ---------- starting data ----------
insert into public.settings (id, data) values (1, '{"defaultPar":10,"vat":15,"leadDays":10,"closeFrom":"2026-11-23","reopen":"2027-01-05","lastDelivery":"2026-12-20","ratePerKg":0}')
  on conflict (id) do nothing;

insert into public.stores (id, name, region) values
  ('belvedere-square', 'Belvedere Square', 'Western Cape'),
  ('blaauwberg', 'Blaauwberg', 'Western Cape'),
  ('durbanville', 'Durbanville', 'Western Cape'),
  ('fish-hoek', 'Fish Hoek', 'Western Cape'),
  ('george', 'George', 'Western Cape'),
  ('kenilworth-centre', 'Kenilworth Centre', 'Western Cape'),
  ('mossel-bay', 'Mossel Bay', 'Western Cape'),
  ('mutualpark', 'Mutualpark', 'Western Cape'),
  ('paarl', 'Paarl', 'Western Cape'),
  ('palmyra-junction', 'Palmyra Junction', 'Western Cape'),
  ('rylands', 'Rylands', 'Western Cape'),
  ('sanlam-direct', 'Sanlam Direct', 'Western Cape'),
  ('somerset-west', 'Somerset West', 'Western Cape'),
  ('stellenbosch', 'Stellenbosch', 'Western Cape'),
  ('westlake', 'Westlake', 'Western Cape'),
  ('fourways', 'Fourways', 'Gauteng'),
  ('simmonds-street', 'Simmonds Street', 'Gauteng'),
  ('ballito', 'Ballito', 'KwaZulu-Natal'),
  ('kloof', 'Kloof', 'KwaZulu-Natal')
  on conflict (id) do nothing;

-- the 123 products from the three price lists (Collection, Corporate, Hamper). par is left blank: HQ sets it in the app.
insert into public.products (code, name, lists, category, pack, per_case, case_price, unit_price, rrp, barcode, kind) values
  ('M810', 'VIP RETAIL - Shortbread Fingers', '{collection}', 'VIP Retail Boxed Biscuits', '175g', '12', 327.0, 27.25, 40.55, '6005086000269', 'bake'),
  ('M830', 'VIP RETAIL - Shortbread Fingers with Stem Ginger', '{collection}', 'VIP Retail Boxed Biscuits', '175g', '12', 327.0, 27.25, 40.55, '6005086000306', 'bake'),
  ('M850', 'VIP RETAIL - Choc Chip & Hazelnut', '{collection}', 'VIP Retail Boxed Biscuits', '150g', '12', 321.0, 26.75, 39.75, '6005086000320', 'bake'),
  ('M862', 'VIP RETAIL - Oat Crunchies with Chocolate', '{collection}', 'VIP Retail Boxed Biscuits', '200g', '12', 321.0, 26.75, 39.75, '6005086000276', 'bake'),
  ('M870', 'VIP RETAIL - Cantucci Biscotti Almond', '{collection}', 'VIP Retail Boxed Biscuits', '160g', '12', 387.0, 32.25, 48.75, '6005086000375', 'bake'),
  ('M953', 'LUNCHBOX HERO - Assorted', '{collection}', 'Lunchbox Hero', '1kg', '1', 116.3, 116.3, 171.0, '6005086000399', 'bake'),
  ('M720', 'FUNKY MINI - Shortbread', '{collection}', 'Funky Mini Cookies', '40 x 10g', '16', 747.0, 46.69, 69.0, '6005086000016', 'bake'),
  ('M725', 'FUNKY MINI - Stem Ginger', '{collection}', 'Funky Mini Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000030', 'bake'),
  ('M740', 'FUNKY MINI - Triple Choc', '{collection}', 'Funky Mini Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000023', 'bake'),
  ('M745', 'FUNKY MINI - Cranberry & White Choc Chip', '{collection}', 'Funky Mini Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000054', 'bake'),
  ('M757-01', 'FUNKY MINI - Choc Chip & Almond', '{collection}', 'Funky Mini Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000085', 'bake'),
  ('M798', 'FUNKY MINI - Oat & Sultana (No Added Sugar)', '{collection}', 'Funky Mini Cookies', '30 x 10g', '30', 1045.0, 34.83, 51.4, '6005086000092', 'bake'),
  ('M940', 'FUNKY MINI - Assorted', '{collection}', 'Funky Mini Cookies', '1kg', '1', 116.3, 116.3, 171.0, '6005086000429', 'bake'),
  ('M941', 'FUNKY MINI - Assorted', '{collection}', 'Funky Mini Cookies', '700g', '1', 83.6, 83.6, 121.5, '6005086000443', 'bake'),
  ('M440-01', 'BUTTONS - Shortbread', '{collection}', 'Buttons', '32 grams', '15', 80.5, 5.37, 117.0, '6005086001105', 'bake'),
  ('M440-06', 'BUTTONS - Choc Chip', '{collection}', 'Buttons', '32 grams', '15', 80.5, 5.37, 117.0, '6005086001112', 'bake'),
  ('M440-12', 'BUTTONS - Double Choc Chip', '{collection}', 'Buttons', '32 grams', '15', 80.5, 5.37, 117.0, '6005086001129', 'bake'),
  ('M440-18', 'BUTTONS - Oat', '{collection}', 'Buttons', '32 grams', '15', 80.5, 5.37, 117.0, '6005086001136', 'bake'),
  ('M440-24', 'BUTTONS - Trail Mix Oat', '{collection}', 'Buttons', '32 grams', '15', 80.5, 5.37, 117.0, '6005086001143', 'bake'),
  ('M770-1', 'FUNKY MINI - Choc Duo', '{collection}', 'Funky Mini Chocolate Coated Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000962', 'bake'),
  ('M770-3', 'FUNKY MINI - Choc Oatie', '{collection}', 'Funky Mini Chocolate Coated Cookies', '40 x10g', '16', 743.0, 46.44, 69.0, '6005086000955', 'bake'),
  ('M770-4', 'FUNKY MINI - Choc Supreme', '{collection}', 'Funky Mini Chocolate Coated Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000948', 'bake'),
  ('M770-5', 'FUNKY MINI - Choc Ginger', '{collection}', 'Funky Mini Chocolate Coated Cookies', '40 x 10g', '16', 743.0, 46.44, 69.0, '6005086000931', 'bake'),
  ('M777-70', 'FUNKY MINI - Choc Oatie', '{collection}', 'Funky Mini Chocolate Coated Cookies (80''s)', '800g', '80 x 10g', 94.7, 94.7, 137.5, '36005086000956', 'bake'),
  ('M777-72', 'FUNKY MINI - Choc Supreme', '{collection}', 'Funky Mini Chocolate Coated Cookies (80''s)', '800g', '80 x 10g', 94.7, 94.7, 137.5, '36005086000949', 'bake'),
  ('M785', 'SHORTBREAD FINGERS - Plain', '{collection}', 'Premium Shortbread', '20 x 15g', '20', 816.0, 40.8, 61.25, '6005086001075', 'bake'),
  ('M792', 'SHORTBREAD FINGERS - Chocolate', '{collection}', 'Premium Shortbread', '20 x 15g', '20', 816.0, 40.8, 61.25, '6005086001099', 'bake'),
  ('M715', 'Cantucci Biscotti Almond MINI', '{collection}', 'Cantucci Biscotti', '40 x 4,5g', '20', 927.0, 46.35, 69.0, '6005086000771', 'bake'),
  ('M794', 'RUSKS - Buttermilk', '{collection}', 'Rusks', '400g', '20', 819.0, 40.95, 60.0, '6005086001280', 'bake'),
  ('M796', 'RUSKS - Bran', '{collection}', 'Rusks', '400g', '20', 800.0, 40.0, 58.5, '6005086001297', 'bake'),
  ('M797-2', 'RUSKS - Health Seed', '{collection}', 'Rusks', '400g', '20', 800.0, 40.0, 58.5, '6005086001327', 'bake'),
  ('M797-3', 'RUSKS - Muesli', '{collection}', 'Rusks', '400g', '20', 800.0, 40.0, 58.5, '6005086001464', 'bake'),
  ('M797', 'RUSKS - Cinnamon & Sultana (No Added Sugar)', '{collection}', 'Rusks', '400g', '20', 800.0, 40.0, 58.5, '6005086001242', 'bake'),
  ('M956', 'RUSKS - Assorted (Bran & Buttermilk)', '{collection}', 'Rusks', '1.4kg', '1', 161.0, 161.0, 236.0, '6005086000467', 'bake'),
  ('M923-01', 'RUSKS - Buttermilk', '{collection}', 'Rusks Homestyle (Unwrapped)', '320g', '12', 416.0, 34.67, 51.25, '6005086000658', 'bake'),
  ('M923-03', 'RUSKS - Bran', '{collection}', 'Rusks Homestyle (Unwrapped)', '320g', '12', 408.0, 34.0, 50.0, '6005086000665', 'bake'),
  ('M923-05', 'RUSKS - Seed', '{collection}', 'Rusks Homestyle (Unwrapped)', '320g', '12', 408.0, 34.0, 50.0, '6005086000672', 'bake'),
  ('M923-07', 'RUSKS - Muesli', '{collection}', 'Rusks Homestyle (Unwrapped)', '320g', '12', 408.0, 34.0, 50.0, '6005086000689', 'bake'),
  ('M784-01', 'RUSKS - Buttermilk', '{collection}', 'Rusks (40''s)', '800g', '40 x 20g', 81.8, 81.8, 118.0, '26005086001284', 'bake'),
  ('M784-03', 'RUSKS - Bran', '{collection}', 'Rusks (40''s)', '800g', '40 x 20g', 81.8, 81.8, 118.0, '26005086001291', 'bake'),
  ('M784-05', 'RUSKS - Seed', '{collection}', 'Rusks (40''s)', '800g', '40 x 20g', 81.8, 81.8, 118.0, '26005086001321', 'bake'),
  ('M784-07', 'RUSKS - Muesli', '{collection}', 'Rusks (40''s)', '800g', '40 x 20g', 81.8, 81.8, 118.0, '26005086001468', 'bake'),
  ('M771-01', 'FUNKY MEDIUM - Shortbread', '{collection}', 'Funky Medium Cookies (14g)', '25 x 14g', '20', 892.0, 44.6, 66.0, '6005086000788', 'bake'),
  ('M771-08', 'FUNKY MEDIUM - Delight with Choc Chip', '{collection}', 'Funky Medium Cookies (14g)', '25 x 14g', '20', 892.0, 44.6, 66.0, '6005086000818', 'bake'),
  ('M771-09', 'FUNKY MEDIUM - Choc Chip', '{collection}', 'Funky Medium Cookies (14g)', '25 x 14g', '20', 892.0, 44.6, 66.0, '6005086000825', 'bake'),
  ('M771-16', 'LUNCHBOX HERO - Yoghurt', '{collection}', 'Lunchbox Hero Medium Cookies (14g)', '25 x 14g', '20', 892.0, 44.6, 66.0, '6005086000986', 'bake'),
  ('M771-17', 'LUNCHBOX HERO - Choc Chip', '{collection}', 'Lunchbox Hero Medium Cookies (14g)', '25 x 14g', '20', 892.0, 44.6, 66.0, '6005086000993', 'bake'),
  ('M645', 'GIANT - Choc Chip', '{collection}', 'Giant Biscuits', '8 x 30g', '12', 397.0, 33.08, 50.0, '6005086001167', 'bake'),
  ('BAR402', 'BARS - Oat & Apricot', '{collection}', 'Snack Bars', '10 x 25g', '12', 482.0, 40.17, 59.75, '6005086001044', 'bake'),
  ('BAR403', 'BARS - Cornflake Crunch', '{collection}', 'Snack Bars', '10 x 25g', '12', 482.0, 40.17, 59.75, '6005086001037', 'bake'),
  ('M801-A', 'CRUNCHIES - Original', '{collection}', 'Oat Crunchies (No Wheat)', '15 x 21g', '20', 601.0, 30.05, 44.5, '6005086001228', 'bake'),
  ('M801-B', 'CRUNCHIES - Chocolate', '{collection}', 'Oat Crunchies (No Wheat)', '15 x 25g', '20', 989.0, 49.45, 71.5, '6005086001235', 'bake'),
  ('M805-01', 'CRUNCHIES - Original with Wheat', '{collection}', 'Oat Crunchies (With Wheat)', '15 x 21g', '20', 601.0, 30.05, 44.5, null, 'bake'),
  ('M805-03', 'CRUNCHIES - Chocolate with Wheat', '{collection}', 'Oat Crunchies (With Wheat)', '15 x 25g', '20', 989.0, 49.45, 71.5, null, 'bake'),
  ('M803-01', 'OAT CRUNCHIES - Original', '{collection}', 'Oat Crunchies (No Wheat 60''s)', '1.25kg', '60 x 21g', 121.5, 121.5, 176.5, '36005086001229', 'bake'),
  ('M803-03', 'OAT CRUNCHIES - Chocolate', '{collection}', 'Oat Crunchies (No Wheat 60''s)', '1.5kg', '60 x 25g', 198.9, 198.9, 289.0, '36005086001236', 'bake'),
  ('M806-01', 'OAT CRUNCHIES - Original', '{collection}', 'Oat Crunchies (With Wheat 60''s)', '1.25kg', '60 x 21g', 121.5, 121.5, 176.5, null, 'bake'),
  ('M806-03', 'OAT CRUNCHIES - Chocolate', '{collection}', 'Oat Crunchies (With Wheat 60''s)', '1.5kg', '60 x 25g', 198.9, 198.9, 289.0, null, 'bake'),
  ('M440-28', 'Buttons - Savoury Cheddar', '{collection}', 'Savoury Cheddar Buttons', '20 grams', '15', 74.9, 4.99, 109.0, '6005086001150', 'bake'),
  ('M446-01', 'Buttons - Savoury Cheddar', '{collection}', 'Savoury Cheddar Buttons', '30 x 8g', '16', 882.0, 55.12, 80.3, '6005086000856', 'bake'),
  ('M441-01', 'Buttons - Savoury Cheddar', '{collection}', 'Savoury Cheddar Buttons', '800 grams', '100 x 8g', 184.0, 184.0, 259.0, '6005086001181', 'bake'),
  ('BIS001', 'SSA Rooibos Shortbread Mini Bites', '{collection}', 'Biscotea', '100g', '12', 194.5, 16.21, 23.6, '80925510679', 'bake'),
  ('M980', 'GIFT PACK - Shortbread Fingers', '{collection}', 'Gift Packs', '2 x 175g', '6', 405.0, 67.5, 103.75, '6005086001310', 'bake'),
  ('M999-L', 'Ribbon Gift Box - 70''s Funky', '{collection}', 'Gift Packs', '70''s', '1', 101.3, 101.3, 161.5, null, 'bake'),
  ('M999-N1', 'GIFT PACK - Funky with Ribbon', '{collection}', 'Gift Packs', '20''s', '9', 416.0, 46.22, 66.75, '6005086001440', 'bake'),
  ('M999-N2', 'GIFT PACK - Funky Chocolate with Ribbon', '{collection}', 'Gift Packs', '20''S', '9', 416.0, 46.22, 66.75, '6005086001457', 'bake'),
  ('M201', 'FUNKY MINI - Shortbread', '{corporate,hamper}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 255.7, 1.28, null, null, 'bake'),
  ('M271', 'FUNKY MINI - Stem Ginger', '{corporate,hamper}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M553', 'FUNKY MINI - Triple Choc', '{corporate,hamper}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M558', 'FUNKY MINI - Cranberry & White Choc Chip', '{corporate,hamper}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M574-04', 'FUNKY MINI - Choc Chip & Almond', '{corporate,hamper}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M588', 'FUNKY MINI - Oat & Sultana (No Added Sugar)', '{corporate}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M968', 'FUNKY MINI - Assorted', '{corporate}', 'Funky Mini Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M585-1', 'FUNKY MINI - Choc Duo', '{corporate}', 'Funky Mini Chocolate Coated Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M585-3', 'FUNKY MINI - Choc Oatie', '{corporate}', 'Funky Mini Chocolate Coated Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M585-4', 'FUNKY MINI - Choc Supreme', '{corporate}', 'Funky Mini Chocolate Coated Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M585-5', 'FUNKY MINI - Choc Ginger', '{corporate}', 'Funky Mini Chocolate Coated Cookies', '2kgs', 'approximately 200 individually wrapped cookies x 10g', 234.7, 1.17, null, null, 'bake'),
  ('M400', 'BUTTONS - Shortbread', '{corporate}', 'Buttons', '32g', '50 packets', 267.0, 5.34, null, null, 'bake'),
  ('M410', 'BUTTONS - Choc Chip', '{corporate}', 'Buttons', '32g', '50 packets', 267.0, 5.34, null, null, 'bake'),
  ('M416', 'BUTTONS - Double Choc Chip', '{corporate}', 'Buttons', '32g', '50 packets', 267.0, 5.34, null, null, 'bake'),
  ('M420', 'BUTTONS - Oat', '{corporate}', 'Buttons', '32g', '50 packets', 267.0, 5.34, null, null, 'bake'),
  ('M424', 'BUTTONS - Trail Mix Oat', '{corporate}', 'Buttons', '32g', '50 packets', 267.0, 5.34, null, null, 'bake'),
  ('M200', 'FUNKY MEDIUM - Shortbread', '{corporate}', 'Funky Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M270', 'FUNKY MEDIUM - Stem Ginger', '{corporate}', 'Funky Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M552', 'FUNKY MEDIUM - Triple Choc', '{corporate}', 'Funky Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M572', 'FUNKY MEDIUM - Delight with Choc Chip', '{corporate}', 'Funky Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M650-10', 'FUNKY MEDIUM - Choc Chip', '{corporate}', 'Funky Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M120', 'SHORTBREAD FINGERS - Plain', '{corporate,hamper}', 'Premium Shortbread', 'Singles', '150 individually wrapped', 322.0, 2.15, null, null, 'bake'),
  ('M140', 'SHORTBREAD FINGERS - Chocolate', '{corporate,hamper}', 'Premium Shortbread', 'Singles', '150 individually wrapped', 360.0, 2.4, null, null, 'bake'),
  ('M290', 'Cantucci Biscotti Almond', '{corporate}', 'Cantucci Biscotti', 'Singles', '150 individually wrapped', 298.9, 1.99, null, null, 'bake'),
  ('M325-1', 'Cantucci Biscotti Almond MINI', '{corporate,hamper}', 'Cantucci Biscotti', 'Singles', '200 individually wrapped', 240.0, 1.2, null, null, 'bake'),
  ('M510', 'RUSKS - Buttermilk', '{corporate}', 'Rusks', 'Singles', '150 individually wrapped', 336.0, 2.24, null, null, 'bake'),
  ('M512', 'RUSKS - Bran', '{corporate}', 'Rusks', 'Singles', '150 individually wrapped', 329.0, 2.19, null, null, 'bake'),
  ('M514', 'RUSKS - Cinnamon & Sultana (No Added Sugar)', '{corporate}', 'Rusks', 'Singles', '150 individually wrapped', 329.0, 2.19, null, null, 'bake'),
  ('M516', 'RUSKS - Seed', '{corporate}', 'Rusks', 'Singles', '150 individually wrapped', 329.0, 2.19, null, null, 'bake'),
  ('M520', 'RUSKS - Muesli', '{corporate}', 'Rusks', 'Singles', '150 individually wrapped', 329.0, 2.19, null, null, 'bake'),
  ('M651', 'LUNCHBOX HERO - Yoghurt', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Twins', '100 individually wrapped', 331.0, 3.31, null, null, 'bake'),
  ('M652', 'LUNCHBOX HERO - Choc Chip', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Twins', '100 individually wrapped', 331.0, 3.31, null, null, 'bake'),
  ('M655', 'LUNCHBOX HERO - Trail', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Twins', '100 individually wrapped', 331.0, 3.31, null, null, 'bake'),
  ('M680', 'LUNCHBOX HERO - Yoghurt', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M681', 'LUNCHBOX HERO - Choc Chip', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M683', 'LUNCHBOX HERO - Crunchie', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('M684', 'LUNCHBOX HERO - Trail Mix', '{corporate}', 'Lunchbox Hero Medium Cookies', 'Singles', '200 Individually wrapped', 360.0, 1.8, null, null, 'bake'),
  ('BAR202', 'BARS - Oat & Apricot', '{corporate}', 'Snack Bars', 'Singles', '120 individually wrapped', 457.0, 3.81, null, null, 'bake'),
  ('BAR203', 'BARS - Cornflake Crunch', '{corporate}', 'Snack Bars', 'Singles', '120 individually wrapped', 457.0, 3.81, null, null, 'bake'),
  ('M636-1', 'CRUNCHIES - Original', '{corporate}', 'Crunchies', 'Singles', '150 individually wrapped', 298.9, 1.99, null, null, 'bake'),
  ('M636-2', 'CRUNCHIES - Chocolate', '{corporate}', 'Crunchies', 'Singles', '150 individually wrapped', 492.0, 3.28, null, null, 'bake'),
  ('M637-1', 'CRUNCHIES - Original', '{corporate}', 'Crunchies (With Wheat)', 'Singles', '150 individually wrapped', 298.9, 1.99, null, null, 'bake'),
  ('M637-2', 'CRUNCHIES - Chocolate', '{corporate}', 'Crunchies (With Wheat)', 'Singles', '150 individually wrapped', 492.0, 3.28, null, null, 'bake'),
  ('M428', 'BUTTONS - Savoury Cheddar', '{corporate}', 'Savoury Cheddar Buttons', '20g', '50 packets', 250.0, 5.0, null, null, 'bake'),
  ('M444-01', 'BUTTONS - Savoury Cheddar', '{corporate}', 'Savoury Cheddar Buttons', 'Twins', '150 individually wrapped', 276.0, 1.84, null, null, 'bake'),
  ('M201-05', 'FUNKY BUTTON - Shortbread', '{corporate}', 'Buttons Conferencing/ Tea Break Options (Unwrapped)', '480g', '3 doypacks  x 480g', 211.5, 70.5, null, null, 'bake'),
  ('M553-05', 'FUNKY BUTTON - Double Choc', '{corporate}', 'Buttons Conferencing/ Tea Break Options (Unwrapped)', '480g', '3 doypacks  x 480g', 211.5, 70.5, null, null, 'bake'),
  ('M328-1', 'Cantucci Biscotti Almond MINI', '{corporate}', 'Buttons Conferencing/ Tea Break Options (Unwrapped)', '450g', '3 doypacks  x 450g', 360.0, 120.0, null, null, 'bake'),
  ('HS-01', 'RIBBON: Organza', '{hamper}', 'Hamper Supplies (packaging)', 'per roll', '20 m', 78.0, null, null, null, 'supply'),
  ('HS-02', 'RIBBON: Gold Flat Ribbon 4mm', '{hamper}', 'Hamper Supplies (packaging)', 'per roll', '100m', 210.0, null, null, null, 'supply'),
  ('HS-03', 'Merchandising Boxes', '{hamper}', 'Hamper Supplies (packaging)', 'each', 'each', 14.0, null, null, null, 'supply'),
  ('HS-04', 'CELLOPHANE ROLL: gold stars', '{hamper}', 'Hamper Supplies (packaging)', 'per roll', '20m', 58.0, null, null, null, 'supply'),
  ('HS-05', 'CELLOPHANE BAGS: 3LB 350 mm x 80 mm', '{hamper}', 'Hamper Supplies (packaging)', '', 'per 100', 60.0, null, null, null, 'supply'),
  ('HS-06', 'CELLOPHANE BAGS: (Cantucci) 305 mm x 75 mm', '{hamper}', 'Hamper Supplies (packaging)', '', 'per 100', 45.0, null, null, null, 'supply'),
  ('HS-07', 'LABELS: Eazi Seal label', '{hamper}', 'Hamper Supplies (packaging)', '', 'per 5000', 1030.0, null, null, null, 'supply'),
  ('HS-08', 'LABELS: Clear Round Label - 30 mm x 30 mm', '{hamper}', 'Hamper Supplies (packaging)', 'per roll', '2000', 110.0, null, null, null, 'supply'),
  ('HS-09', 'Mantelli''s Tape 48mm', '{hamper}', 'Hamper Supplies (packaging)', 'per roll', '100m', 36.0, null, null, null, 'supply')
  on conflict (code) do nothing;

-- ---------- first HQ login ----------
-- 1. In Supabase: Authentication > Users > Add user (tick Auto Confirm User) for the first HQ person.
-- 2. Then run this one line with their email, and they are HQ:
--    update public.profiles set role = 'hq' where email = 'hq@example.com';
