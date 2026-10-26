-- Roles and schemas the local Supabase-compatible stack needs before the
-- GoTrue migrations run (the auth schema is created here because the hosted
-- platform normally provides it).

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
    if not exists (select 1 from pg_roles where rolname = 'postgres') then
        -- The GoTrue migrations grant auth table access to this role.
        create role postgres superuser login;
    end if;
end
$$;

grant anon, authenticated, service_role to authenticator;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- GoTrue uses unqualified table names, so its connection role needs the auth
-- schema on its search path.
alter role postgres set search_path = auth, public;
