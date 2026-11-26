-- Minimal Supabase stand-ins so supabase-schema.sql loads on plain Postgres.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}',
  created_at timestamptz default now()
);

create or replace function auth.jwt() returns jsonb language sql stable as
$$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;

create or replace function auth.uid() returns uuid language sql stable as
$$ select (auth.jwt() ->> 'sub')::uuid $$;

create or replace function auth.role() returns text language sql stable as
$$ select coalesce(auth.jwt() ->> 'role', 'anon') $$;

grant usage on schema auth to anon, authenticated, service_role;

-- Supabase's default privileges: anon, authenticated and service_role get
-- every table and sequence, and EXECUTE on every function, created in
-- public. Shipped SQL must revoke what they shouldn't have.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
