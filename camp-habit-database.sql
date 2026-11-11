-- Camp Habit database setup for Supabase. Paste into SQL Editor and run once.
-- ===== Tables =====
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'Camper' check (char_length(name) between 1 and 20),
  look jsonb not null default '{}'::jsonb,
  island jsonb not null default '{}'::jsonb,
  tz text not null default 'Asia/Bangkok',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  coins integer not null default 0 check (coins >= 0),
  points integer not null default 0
);
create table public.player_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create table public.checkins (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  habit_key text not null check (char_length(habit_key) <= 40),
  points integer not null,
  coins integer not null,
  finished boolean not null default false,
  local_date date not null,
  created_at timestamptz not null default now()
);
create index checkins_user_date on public.checkins (user_id, local_date);
create index checkins_user_created on public.checkins (user_id, created_at);
create table public.items (
  id text primary key,
  kind text not null,
  price integer not null check (price > 0),
  min_level integer not null default 0
);
create table public.inventory (
  user_id uuid not null references auth.users(id) on delete cascade,
  item_id text not null references public.items(id),
  acquired_at timestamptz not null default now(),
  primary key (user_id, item_id)
);
create index inventory_item on public.inventory (item_id);
create table public.claims (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  ref text not null default '',
  period text not null,
  amount integer not null,
  created_at timestamptz not null default now(),
  unique (user_id, kind, ref, period)
);
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 30),
  code text not null unique,
  owner uuid not null references auth.users(id) on delete cascade,
  tz text not null default 'Asia/Bangkok',
  created_at timestamptz not null default now()
);
create index groups_owner on public.groups (owner);
create table public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user on public.group_members (user_id);

-- ===== Row level security =====
alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.player_state enable row level security;
alter table public.checkins enable row level security;
alter table public.items enable row level security;
alter table public.inventory enable row level security;
alter table public.claims enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;

create or replace function public.my_group_ids()
returns setof uuid language sql stable security definer set search_path = '' as $$
  select group_id from public.group_members where user_id = (select auth.uid())
$$;
create or replace function public.is_group_mate(other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.group_members a join public.group_members b on a.group_id = b.group_id
    where a.user_id = (select auth.uid()) and b.user_id = other)
$$;

create policy "profiles: read self and group mates" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_group_mate(id));
create policy "profiles: update self" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "wallets: read self" on public.wallets for select to authenticated using (user_id = (select auth.uid()));
create policy "state: read self" on public.player_state for select to authenticated using (user_id = (select auth.uid()));
create policy "state: update self" on public.player_state for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "checkins: read self" on public.checkins for select to authenticated using (user_id = (select auth.uid()));
create policy "items: read all" on public.items for select to authenticated using (true);
create policy "inventory: read self" on public.inventory for select to authenticated using (user_id = (select auth.uid()));
create policy "claims: read self" on public.claims for select to authenticated using (user_id = (select auth.uid()));
create policy "groups: read my groups" on public.groups for select to authenticated using (id in (select public.my_group_ids()));
create policy "members: read my groups" on public.group_members for select to authenticated using (group_id in (select public.my_group_ids()));

revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (name, look, island, tz, updated_at) on public.profiles to authenticated;
revoke all on public.wallets, public.checkins, public.inventory, public.claims, public.groups, public.group_members, public.items from anon, authenticated;
grant select on public.wallets, public.checkins, public.inventory, public.claims, public.groups, public.group_members, public.items to authenticated;
revoke all on public.player_state from anon, authenticated;
grant select on public.player_state to authenticated;
grant update (data, updated_at) on public.player_state to authenticated;

-- ===== New player setup =====
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, name) values (new.id, coalesce(nullif(left(new.raw_user_meta_data->>'name', 20), ''), 'Camper'));
  insert into public.wallets (user_id) values (new.id);
  insert into public.player_state (user_id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ===== Helpers =====
create or replace function public.island_level(pts integer)
returns integer language sql immutable set search_path = '' as $$
  select case when pts >= 8000 then 4 when pts >= 4000 then 3 when pts >= 1800 then 2 when pts >= 600 then 1 else 0 end
$$;
create or replace function public.my_tz()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select tz from public.profiles where id = (select auth.uid())), 'Asia/Bangkok')
$$;

-- ===== Game actions (the only way coins and points change) =====
create or replace function public.log_progress(p_habit text, p_points integer, p_coins integer, p_finished boolean, p_local_date date)
returns table (checkin_id bigint, coins integer, points integer)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); today date := (now() at time zone public.my_tz())::date; cid bigint;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_points < 1 or p_points > 900 then raise exception 'Points out of range'; end if;
  if p_coins < p_points or p_coins > ceil(p_points * 1.35) then raise exception 'Coins out of range'; end if;
  if p_local_date not between today - 1 and today + 1 then raise exception 'Only today can be logged'; end if;
  insert into public.checkins (user_id, habit_key, points, coins, finished, local_date)
    values (uid, p_habit, p_points, p_coins, p_finished, p_local_date) returning id into cid;
  update public.wallets w set coins = w.coins + p_coins, points = w.points + p_points where w.user_id = uid;
  return query select cid, w.coins, w.points from public.wallets w where w.user_id = uid;
end $$;

create or replace function public.undo_progress(p_checkin bigint)
returns table (coins integer, points integer)
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); c record;
begin
  select * into c from public.checkins ch where ch.id = p_checkin and ch.user_id = uid;
  if not found then raise exception 'Check-in not found'; end if;
  if c.created_at < now() - interval '36 hours' then raise exception 'Too late to undo'; end if;
  if (select w.coins from public.wallets w where w.user_id = uid) < c.coins then raise exception 'You already spent those coins'; end if;
  delete from public.checkins ch where ch.id = p_checkin;
  update public.wallets w set coins = w.coins - c.coins, points = w.points - c.points where w.user_id = uid;
  return query select w.coins, w.points from public.wallets w where w.user_id = uid;
end $$;

create or replace function public.buy_item(p_item text)
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); it record; w record;
begin
  select * into it from public.items where id = p_item;
  if not found then raise exception 'Unknown item'; end if;
  if exists (select 1 from public.inventory where user_id = uid and item_id = p_item) then raise exception 'Already owned'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if public.island_level(w.points) < it.min_level then raise exception 'Reach island level % first', it.min_level + 1; end if;
  if w.coins < it.price then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = coins - it.price where user_id = uid;
  insert into public.inventory (user_id, item_id) values (uid, p_item);
  return w.coins - it.price;
end $$;

create or replace function public.claim_reward(p_kind text, p_ref text default '')
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); tz text := public.my_tz(); loc timestamp := now() at time zone tz; today date := loc::date;
  amt integer; per text; n integer; home integer;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_kind = 'bottle' then
    if not exists (select 1 from public.checkins where user_id = uid and local_date = today and finished) then raise exception 'Finish your habits first'; end if;
    home := case when exists (select 1 from public.inventory where user_id = uid and item_id = 'cabin') then 60
                 when exists (select 1 from public.inventory where user_id = uid and item_id = 'hut') then 45 else 30 end;
    amt := home; per := to_char(today, 'YYYY-MM-DD'); p_ref := '';
  elsif p_kind = 'item' then
    if not exists (select 1 from public.inventory where user_id = uid and item_id = p_ref) then raise exception 'You don''t own that'; end if;
    amt := case p_ref when 'flower' then 5 when 'fire' then 10 when 'palm' then 5 + floor(random() * 8)::int
                       when 'pond' then 10 + floor(random() * 21)::int when 'cat' then 5 else null end;
    if amt is null then raise exception 'That item has no reward'; end if;
    if p_ref = 'fire' and extract(hour from loc) < 17 then raise exception 'Come back after 5 pm'; end if;
    per := to_char(today, 'YYYY-MM-DD');
  elsif p_kind = 'sail' then
    if not exists (select 1 from public.inventory where user_id = uid and item_id = 'boat') then raise exception 'You need a boat'; end if;
    amt := 60 + floor(random() * 61)::int; per := to_char(loc, 'IYYY-IW'); p_ref := '';
  elsif p_kind = 'weekly_bonus' then
    select count(distinct local_date) into n from public.checkins where user_id = uid and finished and local_date >= date_trunc('week', loc)::date;
    if n < 5 then raise exception 'Be active 5 days this week first'; end if;
    amt := 100; per := to_char(loc, 'IYYY-IW'); p_ref := '';
  elsif p_kind = 'monthly_bonus' then
    select count(distinct local_date) into n from public.checkins where user_id = uid and finished and local_date >= date_trunc('month', loc)::date;
    if n < ceil(extract(day from (date_trunc('month', loc) + interval '1 month - 1 day')) * 0.8) then raise exception 'Be active on 80 percent of this month first'; end if;
    amt := 400; per := to_char(loc, 'YYYY-MM'); p_ref := '';
  else raise exception 'Unknown reward';
  end if;
  begin
    insert into public.claims (user_id, kind, ref, period, amount) values (uid, p_kind, coalesce(p_ref, ''), per, amt);
  exception when unique_violation then raise exception 'Already claimed';
  end;
  update public.wallets set coins = coins + amt where user_id = uid;
  return amt;
end $$;

-- ===== Friend groups =====
create or replace function public.create_group(p_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); c text; gid uuid; abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if (select count(*) from public.groups where owner = uid) >= 5 then raise exception 'You can own up to 5 groups'; end if;
  loop
    c := ''; for i in 1..6 loop c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1); end loop;
    exit when not exists (select 1 from public.groups where code = c);
  end loop;
  insert into public.groups (name, code, owner, tz) values (left(trim(p_name), 30), c, uid, public.my_tz()) returning id into gid;
  insert into public.group_members (group_id, user_id) values (gid, uid);
  return c;
end $$;

create or replace function public.join_group(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); g record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into g from public.groups where code = upper(trim(p_code));
  if not found then raise exception 'No group with that code'; end if;
  if (select count(*) from public.group_members where group_id = g.id) >= 20 then raise exception 'This group is full'; end if;
  insert into public.group_members (group_id, user_id) values (g.id, uid) on conflict do nothing;
  return g.id;
end $$;

create or replace function public.leave_group(p_group uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.group_members where group_id = p_group and user_id = auth.uid();
  delete from public.groups g where g.id = p_group and not exists (select 1 from public.group_members m where m.group_id = g.id);
end $$;

create or replace function public.group_leaderboard(p_group uuid)
returns table (user_id uuid, name text, look jsonb, week_points integer, total_points integer)
language plpgsql stable security definer set search_path = '' as $$
declare tz text; wk date;
begin
  if not exists (select 1 from public.group_members gm where gm.group_id = p_group and gm.user_id = auth.uid()) then raise exception 'Not a member'; end if;
  select g.tz into tz from public.groups g where g.id = p_group;
  wk := date_trunc('week', now() at time zone tz)::date;
  return query
    select m.user_id, p.name, p.look,
      coalesce((select sum(c.points) from public.checkins c where c.user_id = m.user_id and c.local_date >= wk), 0)::int,
      w.points
    from public.group_members m join public.profiles p on p.id = m.user_id join public.wallets w on w.user_id = m.user_id
    where m.group_id = p_group
    order by 4 desc, 5 desc;
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.log_progress, public.undo_progress, public.buy_item, public.claim_reward,
  public.create_group, public.join_group, public.leave_group, public.group_leaderboard to authenticated;
grant execute on function public.my_group_ids, public.is_group_mate, public.my_tz, public.island_level to authenticated;

insert into public.items (id, kind, price, min_level) values
('sign','island',180,0),
('flower','island',240,0),
('fire','island',360,0),
('rock','island',480,0),
('palm','island',540,0),
('book','island',720,1),
('boat','island',1200,1),
('hut','island',1800,1),
('pond','island',1500,2),
('cat','island',2400,3),
('cabin','island',4800,3),
('lighthouse','island',6000,4),
('red','hair',300,0),
('pink','hair',600,0),
('hblue','hair',600,0),
('silver','hair',900,0),
('hpurple','hair',600,0),
('mint','hair',600,0),
('bun','hstyle',400,0),
('spiky','hstyle',400,0),
('pigtails','hstyle',400,0),
('curly','hstyle',400,0),
('mohawk','hstyle',600,0),
('eysleepy','eyes',200,0),
('eywink','eyes',300,0),
('eybig','eyes',300,0),
('stripe','outfit',400,0),
('orange','outfit',600,0),
('purple','outfit',600,0),
('overall','outfit',800,0),
('dress','outfit',800,0),
('sweater','outfit',500,0),
('jacket','outfit',700,0),
('rain','outfit',600,0),
('bdress','outfit',800,0),
('pdress','outfit',800,0),
('tux','outfit',1500,0),
('khaki','pants',200,0),
('pwhite','pants',300,0),
('pred','pants',300,0),
('pgreen','pants',300,0),
('glasses','acc',300,0),
('shades','acc',500,0),
('scarf','acc',400,0),
('backpack','acc',600,0),
('mask','acc',300,0),
('mustache','acc',300,0),
('cape','acc',900,0),
('beanie','hat',400,0),
('straw','hat',600,0),
('phones','hat',700,0),
('cap','hat',720,0),
('flowercrown','hat',900,0),
('bow','hat',300,0),
('bandana','hat',400,0),
('party','hat',500,0),
('catears','hat',800,0),
('witch','hat',900,0),
('halo','hat',1500,0),
('crown','hat',2400,0),
('bnight','banner',400,0),
('bsakura','banner',600,0),
('bocean','banner',400,0),
('bforest','banner',500,0),
('bcandy','banner',600,0),
('baurora','banner',900,0),
('bretro','banner',1200,0),
('towl','title',200,0),
('tbird','title',200,0),
('tsun','title',200,0),
('thustle','title',500,0),
('tlegend','title',3000,0);
-- Homes, furniture and habit rewards
insert into public.items (id, kind, price, min_level) values
('lodge','island',9000,4),
('stool','home',60,0),
('ftable','home',120,0),
('plant','home',90,0),
('lamp','home',150,0),
('rug','home',200,0),
('painting','home',180,0),
('window','home',160,0),
('clock','home',220,0),
('shelf','home',260,0),
('sofa','home',450,0),
('aquarium','home',600,0),
('fireplace','home',900,0),
('sneakers','reward',1,0),
('treadmill','reward',1,0),
('rtrophy','reward',1,0),
('yogamat','reward',1,0),
('dumbbells','reward',1,0),
('punchbag','reward',1,0),
('bookstack','reward',1,0),
('bookcase','reward',1,0),
('armchair','reward',1,0),
('cushion','reward',1,0),
('bonsai','reward',1,0),
('lantern','reward',1,0),
('guitar','reward',1,0),
('easel','reward',1,0),
('piano','reward',1,0),
('corkboard','reward',1,0),
('desk','reward',1,0),
('globe','reward',1,0),
('nightlamp','reward',1,0),
('bed','reward',1,0),
('wardrobe','reward',1,0),
('watercooler','reward',1,0),
('stove','reward',1,0),
('fridge','reward',1,0),
('radio','reward',1,0),
('arcade','reward',1,0),
('startrophy','reward',1,0)
on conflict (id) do update set kind = excluded.kind, price = excluded.price, min_level = excluded.min_level;

create table if not exists private.milestones (item_id text primary key references public.items(id), presets text[], need integer not null);
insert into private.milestones (item_id, presets, need) values
('sneakers',array['walk','run','cycle','swim']::text[],5),
('treadmill',array['walk','run','cycle','swim']::text[],20),
('rtrophy',array['walk','run','cycle','swim']::text[],50),
('yogamat',array['pushups','gym','cold']::text[],5),
('dumbbells',array['pushups','gym','cold']::text[],20),
('punchbag',array['pushups','gym','cold']::text[],50),
('bookstack',array['reading','study','language']::text[],5),
('bookcase',array['reading','study','language']::text[],20),
('armchair',array['reading','study','language']::text[],50),
('cushion',array['meditate','journal','screen']::text[],5),
('bonsai',array['meditate','journal','screen']::text[],20),
('lantern',array['meditate','journal','screen']::text[],50),
('guitar',array['music','draw']::text[],5),
('easel',array['music','draw']::text[],20),
('piano',array['music','draw']::text[],50),
('corkboard',array['coding','deep']::text[],5),
('desk',array['coding','deep']::text[],20),
('globe',array['coding','deep']::text[],50),
('nightlamp',array['bed','sleep','tidy','teeth']::text[],5),
('bed',array['bed','sleep','tidy','teeth']::text[],20),
('wardrobe',array['bed','sleep','tidy','teeth']::text[],50),
('watercooler',array['water','fruit','cook','vit']::text[],5),
('stove',array['water','fruit','cook','vit']::text[],20),
('fridge',array['water','fruit','cook','vit']::text[],50),
('radio',null::text[],10),
('arcade',null::text[],50),
('startrophy',null::text[],150)
on conflict (item_id) do update set presets = excluded.presets, need = excluded.need;

create or replace function public.buy_item(p_item text)
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); it record; w record; prev text;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into it from public.items where id = p_item;
  if not found then raise exception 'Unknown item'; end if;
  if it.kind = 'reward' then raise exception 'Earn this one with your habits'; end if;
  if exists (select 1 from public.inventory where user_id = uid and item_id = p_item) then raise exception 'Already owned'; end if;
  prev := case p_item when 'cabin' then 'hut' when 'lodge' then 'cabin' else null end;
  if prev is not null and not exists (select 1 from public.inventory where user_id = uid and item_id = prev) then raise exception 'Upgrade your home one step at a time'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if private.island_level(w.points) < it.min_level then raise exception 'Reach island level % first', it.min_level + 1; end if;
  if w.coins < it.price then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = coins - it.price where user_id = uid;
  insert into public.inventory (user_id, item_id) values (uid, p_item);
  return w.coins - it.price;
end $$;

create or replace function private.home_bottle(uid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  with h as (
    select case when exists (select 1 from public.inventory where user_id = uid and item_id = 'lodge') then 'lodge'
                when exists (select 1 from public.inventory where user_id = uid and item_id = 'cabin') then 'cabin'
                when exists (select 1 from public.inventory where user_id = uid and item_id = 'hut') then 'hut' else 'tent' end as home),
  f as (select count(*)::int as n from public.inventory i join public.items it on it.id = i.item_id where i.user_id = uid and it.kind in ('home','reward'))
  select (case home when 'lodge' then 80 when 'cabin' then 60 when 'hut' then 45 else 30 end)
       + 2 * least(f.n, case home when 'lodge' then 20 when 'cabin' then 14 when 'hut' then 8 else 4 end)
  from h, f
$$;
revoke all on function private.home_bottle(uuid) from public, anon, authenticated;

create or replace function public.claim_reward(p_kind text, p_ref text default '')
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); tz text := private.my_tz(); loc timestamp := now() at time zone tz; today date := loc::date;
  amt integer; per text; n integer; ms record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_kind = 'bottle' then
    if not exists (select 1 from public.checkins where user_id = uid and local_date = today and finished) then raise exception 'Finish your habits first'; end if;
    amt := private.home_bottle(uid); per := to_char(today, 'YYYY-MM-DD'); p_ref := '';
  elsif p_kind = 'item' then
    if not exists (select 1 from public.inventory where user_id = uid and item_id = p_ref) then raise exception 'You don''t own that'; end if;
    amt := case p_ref when 'flower' then 5 when 'fire' then 10 when 'palm' then 5 + floor(random() * 8)::int
                       when 'pond' then 10 + floor(random() * 21)::int when 'cat' then 5 else null end;
    if amt is null then raise exception 'That item has no reward'; end if;
    if p_ref = 'fire' and extract(hour from loc) < 17 then raise exception 'Come back after 5 pm'; end if;
    per := to_char(today, 'YYYY-MM-DD');
  elsif p_kind = 'sail' then
    if not exists (select 1 from public.inventory where user_id = uid and item_id = 'boat') then raise exception 'You need a boat'; end if;
    amt := 60 + floor(random() * 61)::int; per := to_char(loc, 'IYYY-IW'); p_ref := '';
  elsif p_kind = 'weekly_bonus' then
    select count(distinct local_date) into n from public.checkins where user_id = uid and finished and local_date >= date_trunc('week', loc)::date;
    if n < 5 then raise exception 'Be active 5 days this week first'; end if;
    amt := 100; per := to_char(loc, 'IYYY-IW'); p_ref := '';
  elsif p_kind = 'monthly_bonus' then
    select count(distinct local_date) into n from public.checkins where user_id = uid and finished and local_date >= date_trunc('month', loc)::date;
    if n < ceil(extract(day from (date_trunc('month', loc) + interval '1 month - 1 day')) * 0.8) then raise exception 'Be active on 80 percent of this month first'; end if;
    amt := 400; per := to_char(loc, 'YYYY-MM'); p_ref := '';
  elsif p_kind = 'milestone' then
    select * into ms from private.milestones where item_id = p_ref;
    if not found then raise exception 'Unknown reward'; end if;
    with ck as (
      select c.habit_key, case when position(':' in c.habit_key) > 0 then split_part(c.habit_key, ':', 1)
        else (select h->>'p' from public.player_state ps, jsonb_array_elements(ps.data->'habits') h where ps.user_id = uid and h->>'id' = c.habit_key limit 1) end as preset
      from public.checkins c where c.user_id = uid and c.finished)
    select count(*) into n from ck where ms.presets is null or ck.preset = any(ms.presets);
    if n < ms.need then raise exception 'Keep going. % of % done', n, ms.need; end if;
    amt := 0; per := 'once';
    insert into public.inventory (user_id, item_id) values (uid, p_ref) on conflict do nothing;
  else raise exception 'Unknown reward';
  end if;
  begin
    insert into public.claims (user_id, kind, ref, period, amount) values (uid, p_kind, coalesce(p_ref, ''), per, amt);
  exception when unique_violation then raise exception 'Already claimed';
  end;
  if amt > 0 then update public.wallets set coins = coins + amt where user_id = uid; end if;
  return amt;
end $$;

-- wake-up check-ins count toward rest rewards
update private.milestones set presets = array['wake','bed','sleep','tidy','teeth']::text[] where item_id in ('nightlamp','bed','wardrobe');

-- clearing trees, bushes, rocks and stumps costs coins
create or replace function public.clear_nature(p_kind text)
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cost integer; w record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  cost := case p_kind when 'oak' then 25 when 'pine' then 25 when 'boulder' then 15 when 'stump' then 12 when 'berry' then 10 when 'bush' then 8 else null end;
  if cost is null then raise exception 'You can''t clear that'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if w.coins < cost then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = coins - cost where user_id = uid;
  return w.coins - cost;
end $$;
revoke all on function public.clear_nature(text) from public, anon;
grant execute on function public.clear_nature(text) to authenticated;

-- price rebalance (island/home up, cosmetics down)
update public.items i set price = v.p from (values ('sign',270),('flower',480),('fire',720),('rock',1200),('palm',1080),('book',1800),('boat',3000),('hut',3600),('pond',3750),('cat',4800),('cabin',9600),('lodge',18000),('lighthouse',12000),('red',150),('pink',300),('hblue',300),('silver',450),('hpurple',300),('mint',300),('bun',200),('spiky',200),('pigtails',200),('curly',200),('mohawk',300),('eysleepy',100),('eywink',150),('eybig',150),('stripe',200),('orange',300),('purple',300),('overall',400),('dress',400),('sweater',250),('jacket',350),('rain',300),('bdress',400),('pdress',400),('tux',750),('khaki',100),('pwhite',150),('pred',150),('pgreen',150),('glasses',150),('shades',250),('scarf',200),('backpack',300),('mask',150),('mustache',150),('cape',450),('beanie',200),('straw',300),('phones',350),('cap',350),('flowercrown',450),('bow',150),('bandana',200),('party',250),('catears',400),('witch',450),('halo',750),('crown',1200),('bnight',200),('bsakura',300),('bocean',200),('bforest',250),('bcandy',300),('baurora',450),('bretro',600),('towl',100),('tbird',100),('tsun',100),('thustle',250),('tlegend',1500),('stool',90),('ftable',180),('plant',150),('lamp',240),('rug',320),('painting',300),('window',260),('clock',350),('shelf',420),('sofa',800),('aquarium',1100),('fireplace',1800)) as v(id,p) where i.id = v.id and i.kind <> 'reward';

-- clearing with workout energy: 1 energy per finished workout check-in
create or replace function private.energy_left(uid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  with ck as (
    select case when position(':' in c.habit_key) > 0 then split_part(c.habit_key, ':', 1)
      else (select h->>'p' from public.player_state ps, jsonb_array_elements(ps.data->'habits') h where ps.user_id = uid and h->>'id' = c.habit_key limit 1) end as preset
    from public.checkins c where c.user_id = uid and c.finished)
  select (select count(*)::int from ck where preset = any(array['walk','run','cycle','swim','pushups','gym','stretch','yoga','plank','jumprope']))
       - coalesce((select sum(amount)::int from public.claims where user_id = uid and kind = 'energy'), 0)
$$;
revoke all on function private.energy_left(uuid) from public, anon, authenticated;
drop function if exists public.clear_nature(text);
-- public.clear_nature(p_kind text, p_pay text default 'coins'): see migration rebalance_prices_and_energy_clearing
create or replace function public.clear_nature(p_kind text, p_pay text default 'coins')
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cost integer; w record; en integer;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_pay = 'energy' then
    cost := case p_kind when 'oak' then 3 when 'pine' then 3 when 'boulder' then 2 when 'stump' then 2 when 'berry' then 1 when 'bush' then 1 else null end;
    if cost is null then raise exception 'You can''t clear that'; end if;
    en := private.energy_left(uid);
    if en < cost then raise exception 'Not enough workout energy'; end if;
    insert into public.claims (user_id, kind, ref, period, amount) values (uid, 'energy', gen_random_uuid()::text, 'spend', cost);
    return en - cost;
  end if;
  cost := case p_kind when 'oak' then 25 when 'pine' then 25 when 'boulder' then 15 when 'stump' then 12 when 'berry' then 10 when 'bush' then 8 else null end;
  if cost is null then raise exception 'You can''t clear that'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if w.coins < cost then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = coins - cost where user_id = uid;
  return w.coins - cost;
end $$;
revoke all on function public.clear_nature(text, text) from public, anon;
grant execute on function public.clear_nature(text, text) to authenticated;

-- garden plots, crop research (Field Journal)
create table if not exists public.plots (
  user_id uuid not null references auth.users(id) on delete cascade,
  slot integer not null check (slot between 0 and 5),
  crop text not null,
  planted_at timestamptz not null default now(),
  primary key (user_id, slot)
);
alter table public.plots enable row level security;
create policy "own plots" on public.plots for select to authenticated using (user_id = (select auth.uid()));
create table if not exists public.research (
  user_id uuid not null references auth.users(id) on delete cascade,
  crop text not null,
  stage integer not null check (stage between 1 and 3),
  rp integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (user_id, crop, stage)
);
alter table public.research enable row level security;
create policy "own research" on public.research for select to authenticated using (user_id = (select auth.uid()));
create table if not exists private.crops (id text primary key, seed integer not null, sell integer not null, days integer not null, starter boolean not null default false);
insert into private.crops (id, seed, sell, days, starter) values
('basil',20,45,3,true),('pakbung',15,32,2,true),('chili',25,60,4,true),('lemongrass',30,75,5,false),('galangal',40,100,6,false),
('eggplant',30,75,5,false),('makrut',60,160,8,false),('rice',50,130,7,false),('pumpkin',45,115,6,false),('tomato',35,85,5,false)
on conflict (id) do update set seed = excluded.seed, sell = excluded.sell, days = excluded.days, starter = excluded.starter;
create or replace function private.rp_left(uid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  with ck as (
    select case when position(':' in c.habit_key) > 0 then split_part(c.habit_key, ':', 1)
      else (select h->>'p' from public.player_state ps, jsonb_array_elements(ps.data->'habits') h where ps.user_id = uid and h->>'id' = c.habit_key limit 1) end as preset
    from public.checkins c where c.user_id = uid and c.finished)
  select (select count(*)::int from ck where preset = any(array['reading','study','language','coding','music','deep','journal','draw','gratitude','meditate']))
       - coalesce((select sum(rp)::int from public.research where user_id = uid), 0)
$$;
revoke all on function private.rp_left(uuid) from public, anon, authenticated;
create or replace function public.plant_crop(p_slot integer, p_crop text)
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); c record; w record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_slot < 0 or p_slot > 5 then raise exception 'Unknown plot'; end if;
  select * into c from private.crops where id = p_crop;
  if not found then raise exception 'Unknown crop'; end if;
  if exists (select 1 from public.plots where user_id = uid and slot = p_slot) then raise exception 'That plot is already planted'; end if;
  if not c.starter and not exists (select 1 from public.research where user_id = uid and crop = p_crop and stage = 1) then raise exception 'Discover this crop in your journal first'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if w.coins < c.seed then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = coins - c.seed where user_id = uid;
  insert into public.plots (user_id, slot, crop) values (uid, p_slot, p_crop);
  return w.coins - c.seed;
end $$;
create or replace function public.harvest_crop(p_slot integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); pl record; c record; n integer; w record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into pl from public.plots where user_id = uid and slot = p_slot;
  if not found then raise exception 'Nothing planted there'; end if;
  select * into c from private.crops where id = pl.crop;
  select count(distinct local_date) into n from public.checkins where user_id = uid and finished and created_at > pl.planted_at;
  if n < c.days then raise exception 'Not ready yet. % of % days watered', n, c.days; end if;
  delete from public.plots where user_id = uid and slot = p_slot;
  insert into public.claims (user_id, kind, ref, period, amount) values (uid, 'harvest', pl.crop, gen_random_uuid()::text, c.sell);
  update public.wallets set coins = coins + c.sell where user_id = uid returning * into w;
  return w.coins;
end $$;
create or replace function public.research_unlock(p_crop text, p_stage integer, p_pay text default 'rp')
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cost integer; price integer; left_rp integer; w record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from private.crops where id = p_crop) then raise exception 'Unknown crop'; end if;
  if p_stage not between 1 and 3 then raise exception 'Unknown stage'; end if;
  if not exists (select 1 from public.claims where user_id = uid and kind = 'harvest') and not exists (select 1 from public.plots where user_id = uid) then raise exception 'Plant your first crop to open the journal'; end if;
  if p_stage > 1 and not exists (select 1 from public.research where user_id = uid and crop = p_crop and stage = p_stage - 1) then raise exception 'Unlock the earlier page first'; end if;
  if exists (select 1 from public.research where user_id = uid and crop = p_crop and stage = p_stage) then raise exception 'Already unlocked'; end if;
  cost := case p_stage when 1 then 3 when 2 then 5 else 8 end;
  price := cost * 30;
  if p_pay = 'rp' then
    left_rp := private.rp_left(uid);
    if left_rp < cost then raise exception 'Not enough research points'; end if;
    insert into public.research (user_id, crop, stage, rp) values (uid, p_crop, p_stage, cost);
    return left_rp - cost;
  end if;
  select * into w from public.wallets where user_id = uid for update;
  if w.coins < price then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = w.coins - price where user_id = uid;
  insert into public.research (user_id, crop, stage, rp) values (uid, p_crop, p_stage, 0);
  return w.coins - price;
end $$;
revoke all on function public.plant_crop(integer, text), public.harvest_crop(integer), public.research_unlock(text, integer, text) from public, anon;
grant execute on function public.plant_crop(integer, text), public.harvest_crop(integer), public.research_unlock(text, integer, text) to authenticated;

-- paths and fences: pay per painted tile (positions are kept in player_state)
create or replace function public.spend_deco(p_kind text, p_count integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); each integer; total integer; w record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_count < 1 or p_count > 500 then raise exception 'Too many tiles at once'; end if;
  each := case p_kind when 'dirt' then 1 when 'gravel' then 2 when 'stone' then 4 when 'plank' then 5 when 'brick' then 6
                      when 'wfence' then 8 when 'picket' then 10 when 'swall' then 10 else null end;
  if each is null then raise exception 'Unknown tile'; end if;
  total := each * p_count;
  select * into w from public.wallets where user_id = uid for update;
  if w.coins < total then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = w.coins - total where user_id = uid;
  return w.coins - total;
end $$;
revoke all on function public.spend_deco(text, integer) from public, anon;
grant execute on function public.spend_deco(text, integer) to authenticated;

-- farmland tiles (3 free + bought), plots on any tile, new island/home items, well/hammock/hot spring daily coins, scarecrow +10% crop sales
-- (applied as migration farmland_and_more_items; functions buy_farmland, private.farmland_owned, plant_crop, harvest_crop, claim_reward updated)
alter table public.plots drop constraint if exists plots_slot_check;
alter table public.plots add constraint plots_slot_check check (slot between 0 and 4095);
insert into public.items (id, kind, price, min_level) values
('bench','island',200,0),('lamppost','island',260,0),('mailbox','island',220,0),('well','island',1500,1),('hammock','island',1800,1),('scarecrow','island',1200,1),
('dock','island',2200,2),('windmill','island',4000,2),('spring','island',6000,3),('statue','island',8000,4),('tower','island',10000,4),
('tv','home',500,0),('beanbag','home',300,0),('mirror','home',250,0),('wallshelf','home',220,0),('bigrug','home',480,0),('dtable','home',420,0),('counter','home',600,0),('cactus','home',120,0)
on conflict (id) do update set kind = excluded.kind, price = excluded.price, min_level = excluded.min_level;
create or replace function private.farmland_owned(uid uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select 3 + (select count(*)::int from public.claims where user_id = uid and kind = 'farmland')
$$;
create or replace function public.buy_farmland()
returns integer language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); w record;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if private.farmland_owned(uid) >= 200 then raise exception 'That is plenty of farmland'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if w.coins < 25 then raise exception 'Not enough coins'; end if;
  update public.wallets set coins = w.coins - 25 where user_id = uid;
  insert into public.claims (user_id, kind, ref, period, amount) values (uid, 'farmland', gen_random_uuid()::text, 'buy', 25);
  return w.coins - 25;
end $$;

-- furniture unlocks by home tier (0 tent, 1 hut, 2 cabin); cat moves to island level 3
alter table public.items add column if not exists min_home integer not null default 0;
update public.items set min_home = 1 where id in ('window','clock','painting','shelf','mirror','wallshelf','dtable','sofa');
update public.items set min_home = 2 where id in ('tv','aquarium','fireplace','bigrug','counter');
update public.items set min_level = 2 where id = 'cat';
-- public.buy_item now also checks items.min_home against the player's home (see migration furniture_by_home_tier)

-- chess habit + cosmetics (Nov 2026)
-- chess habit, cheaper and more cosmetics
insert into public.items (id,kind,price,min_level) values
('red','hair',100,0),
('pink','hair',200,0),
('hblue','hair',200,0),
('silver','hair',250,0),
('hpurple','hair',200,0),
('mint','hair',200,0),
('bun','hstyle',100,0),
('spiky','hstyle',100,0),
('pigtails','hstyle',100,0),
('curly','hstyle',100,0),
('mohawk','hstyle',200,0),
('eysleepy','eyes',50,0),
('eywink','eyes',100,0),
('eybig','eyes',100,0),
('stripe','outfit',100,0),
('orange','outfit',200,0),
('purple','outfit',200,0),
('overall','outfit',250,0),
('dress','outfit',250,0),
('sweater','outfit',150,0),
('jacket','outfit',200,0),
('rain','outfit',200,0),
('bdress','outfit',250,0),
('pdress','outfit',250,0),
('tux','outfit',450,0),
('khaki','pants',50,0),
('pwhite','pants',100,0),
('pred','pants',100,0),
('pgreen','pants',100,0),
('glasses','acc',100,0),
('shades','acc',150,0),
('scarf','acc',100,0),
('backpack','acc',200,0),
('mask','acc',100,0),
('mustache','acc',100,0),
('cape','acc',250,0),
('beanie','hat',100,0),
('straw','hat',200,0),
('phones','hat',200,0),
('cap','hat',200,0),
('flowercrown','hat',250,0),
('bow','hat',100,0),
('bandana','hat',100,0),
('party','hat',150,0),
('catears','hat',250,0),
('witch','hat',250,0),
('halo','hat',450,0),
('crown','hat',700,0),
('bnight','banner',100,0),
('bsakura','banner',200,0),
('bocean','banner',100,0),
('bforest','banner',150,0),
('bcandy','banner',200,0),
('baurora','banner',250,0),
('bretro','banner',350,0),
('towl','title',50,0),
('tbird','title',50,0),
('tsun','title',50,0),
('thustle','title',150,0),
('tlegend','title',900,0),
('hgreen','hair',150,0),
('hwhite','hair',200,0),
('hteal','hair',150,0),
('hcoral','hair',150,0),
('hlav','hair',150,0),
('pinktee','outfit',100,0),
('suntee','outfit',100,0),
('greyhood','outfit',150,0),
('minthood','outfit',150,0),
('mintsweat','outfit',150,0),
('redjacket','outfit',200,0),
('blacktank','outfit',50,0),
('greenstripe','outfit',100,0),
('pblue','pants',50,0),
('ppink','pants',50,0),
('pgrey','pants',50,0),
('pyellow','pants',50,0),
('bmint','banner',100,0),
('bpeach','banner',100,0),
('bgrape','banner',150,0),
('bsnow','banner',150,0),
('bjungle','banner',200,0),
('bcity','banner',250,0),
('tdream','title',50,0),
('tcoffee','title',50,0),
('tzen','title',100,0),
('tsmile','title',50,0),
('tchef','title',100,0),
('tmusic','title',50,0),
('tchamp','title',400,0)
on conflict (id) do update set price = excluded.price where public.items.kind <> 'reward';
update private.milestones set presets = array_append(presets,'chess') where item_id in ('corkboard','desk','globe') and not ('chess' = any(presets));
create or replace function private.rp_left(uid uuid)
 returns integer language sql stable security definer set search_path to ''
as $function$
  with ck as (
    select case when position(':' in c.habit_key) > 0 then split_part(c.habit_key, ':', 1)
      else (select h->>'p' from public.player_state ps, jsonb_array_elements(ps.data->'habits') h where ps.user_id = uid and h->>'id' = c.habit_key limit 1) end as preset
    from public.checkins c where c.user_id = uid and c.finished)
  select (select count(*)::int from ck where preset = any(array['reading','study','language','coding','music','deep','journal','draw','gratitude','meditate','chess']))
       - coalesce((select sum(rp)::int from public.research where user_id = uid), 0)
$function$;

-- friend profiles and island visits (Nov 2026)
create or replace function public.friend_view(p_user uuid)
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare uid uuid := auth.uid(); r jsonb;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if p_user <> uid and not exists (
    select 1 from public.group_members a join public.group_members b on a.group_id = b.group_id
    where a.user_id = uid and b.user_id = p_user) then raise exception 'Not in a group with this player'; end if;
  select jsonb_build_object(
    'name', p.name, 'look', p.look, 'island', p.island,
    'points', coalesce(w.points, 0),
    'done', (select count(*) from public.checkins c where c.user_id = p_user and c.finished),
    'days', (select count(distinct c.local_date) from public.checkins c where c.user_id = p_user),
    'items', (select count(*) from public.inventory i where i.user_id = p_user),
    'plots', coalesce((select jsonb_agg(jsonb_build_object('slot', pl.slot, 'crop', pl.crop, 't', pl.planted_at)) from public.plots pl where pl.user_id = p_user), '[]'::jsonb))
  into r from public.profiles p left join public.wallets w on w.user_id = p.id where p.id = p_user;
  if r is null then raise exception 'Player not found'; end if;
  return r;
end $function$;
revoke all on function public.friend_view(uuid) from public, anon;
grant execute on function public.friend_view(uuid) to authenticated;
