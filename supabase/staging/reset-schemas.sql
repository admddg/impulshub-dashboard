drop schema if exists crm cascade;
drop schema if exists private cascade;
drop schema if exists public cascade;
create schema public;
alter schema public owner to pg_database_owner;
comment on schema public is 'standard public schema';
