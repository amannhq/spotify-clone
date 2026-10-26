-- Local Supabase-compatible schema for the spotify-clone app.
-- Mirrors types/db.ts so the application code works unchanged.

create extension if not exists pgcrypto;

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin bypassrls;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticator') then
        create role authenticator login noinherit;
    end if;
end
$$;

grant anon, authenticated, service_role to authenticator;

do $$
begin
    create type pricing_plan_interval as enum ('day', 'week', 'month', 'year');
exception
    when duplicate_object then null;
end
$$;

do $$
begin
    create type pricing_type as enum ('one_time', 'recurring');
exception
    when duplicate_object then null;
end
$$;

do $$
begin
    create type subscription_status as enum (
        'trialing', 'active', 'canceled', 'incomplete',
        'incomplete_expired', 'past_due', 'unpaid'
    );
exception
    when duplicate_object then null;
end
$$;

create table if not exists public.users (
    id uuid primary key references auth.users (id) on delete cascade,
    first_name text,
    last_name text,
    full_name text,
    avatar_url text,
    billing_address jsonb,
    payment_method jsonb
);

create table if not exists public.songs (
    id bigserial primary key,
    created_at timestamptz not null default now(),
    title text,
    author text,
    song_path text,
    image_path text,
    user_id uuid references auth.users (id) on delete set null
);

create table if not exists public.liked_songs (
    created_at timestamptz not null default now(),
    song_id bigint not null references public.songs (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    primary key (user_id, song_id)
);

create table if not exists public.products (
    id text primary key,
    active boolean,
    name text,
    description text,
    image text,
    metadata jsonb
);

create table if not exists public.prices (
    id text primary key,
    active boolean,
    currency text,
    description text,
    metadata jsonb,
    product_id text references public.products (id) on delete set null,
    trial_period_days integer,
    type pricing_type,
    unit_amount integer,
    interval pricing_plan_interval,
    interval_count integer
);

create table if not exists public.customers (
    id uuid primary key references auth.users (id) on delete cascade,
    stripe_customer_id text
);

create table if not exists public.subscriptions (
    id text primary key,
    user_id uuid not null references auth.users (id) on delete cascade,
    status subscription_status,
    metadata jsonb,
    price_id text references public.prices (id) on delete set null,
    quantity integer,
    cancel_at_period_end boolean,
    created timestamptz not null default now(),
    current_period_start timestamptz not null default now(),
    current_period_end timestamptz not null default now(),
    ended_at timestamptz,
    cancel_at timestamptz,
    canceled_at timestamptz,
    trial_start timestamptz,
    trial_end timestamptz
);

-- Keep public.users in step with auth.users so the app can read the
-- profile of any account it creates.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.users (id, first_name, last_name, full_name)
    values (
        new.id,
        new.raw_user_meta_data ->> 'first_name',
        new.raw_user_meta_data ->> 'last_name',
        new.raw_user_meta_data ->> 'full_name'
    )
    on conflict (id) do nothing;
    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

grant usage on schema public to anon, authenticated, service_role, authenticator;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
alter default privileges in schema public
    grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
    grant all on sequences to anon, authenticated, service_role;
