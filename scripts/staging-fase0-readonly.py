#!/usr/bin/env python3
"""Fase 0: reconciliação somente-leitura do staging autorizado."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pg8000

ROOT = Path(__file__).resolve().parents[1]
REF = "nfratueiutxnypbxfnmi"
PROD = "mtxnwtqwfagjzkvgsncs"
CLI = r"C:\Users\caiop\AppData\Local\hermes\node\npx.cmd"

ADVANCE_MIGRATIONS = [
    "20260922000000_crm_baseline.sql",
    "20260922000001_crm_opportunity_attribution.sql",
    "20260923000000_crm_stevo_parser.sql",
    "20260923000001_crm_schedule_stevo_parser.sql",
    "20260923000002_crm_public_read_views.sql",
    "20260923000003_crm_public_write_rpcs.sql",
    "20260923000004_client_users_attendant_role.sql",
    "20260924000000_crm_event_bridge.sql",
    "20260925000000_crm_fix_owners_can_write.sql",
    "20260925000001_crm_board_counts_filtered.sql",
    "20260925000002_crm_stage_version_guard.sql",
    "20260925000003_crm_contacts_view_filters.sql",
    "20260927000000_imp229_rls_client_ids.sql",
    "20260928000000_imp213_role_visibility.sql",
    "20260928000001_imp213_hotfix_card_history_tenant_filter.sql",
    "20260928000002_imp226a_open_card_on_individual_conversation.sql",
    "20260929000001_imp214_two_owners.sql",
    "20260930000000_imp216_split_flags.sql",
    "20261001000000_imp230_form_intake.sql",
    "20261002000000_imp231_meta_ads_raw_retention.sql",
]


def connection_env() -> dict[str, str]:
    probe = subprocess.run(
        [CLI, "supabase", "db", "dump", "--project-ref", REF,
         "--schema", "crm,public,private", "--dry-run"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    values = {}
    for key in ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE"]:
        match = re.search(rf'export {key}="([^"]*)"', probe.stdout)
        if not match:
            raise RuntimeError(f"credencial {key} ausente no dry-run do alvo {REF}")
        values[key] = match.group(1)
    endpoint = values["PGHOST"]
    if REF not in endpoint or PROD in endpoint:
        raise RuntimeError(f"BLOQUEIO: endpoint inesperado para staging: {endpoint}")
    if PROD in json.dumps({"host": endpoint, "user": values["PGUSER"]}):
        raise RuntimeError("BLOQUEIO: credencial resolveu para produção")
    return values


def fetch(cur, sql, params=None):
    cur.execute(sql, params or ())
    columns = [desc[0] for desc in cur.description] if cur.description else []
    return [dict(zip(columns, row)) for row in cur.fetchall()] if columns else []


def one(cur, sql, params=None):
    cur.execute(sql, params or ())
    row = cur.fetchone()
    return row[0] if row else None


def main():
    env = connection_env()
    conn = pg8000.connect(
        user=env["PGUSER"], password=env["PGPASSWORD"], host=env["PGHOST"],
        port=int(env["PGPORT"]), database=env["PGDATABASE"], ssl_context=True,
    )
    cur = conn.cursor()
    try:
        cur.execute("begin read only")
        before = fetch(cur, "select current_user, session_user, current_database(), inet_server_addr()")
        cur.execute("set local role postgres")
        after = fetch(cur, "select current_user, session_user")

        ledger_regclass = one(cur, "select to_regclass('supabase_migrations.schema_migrations')")
        ledger = fetch(cur, """
            select version, name
            from supabase_migrations.schema_migrations
            order by version
        """) if ledger_regclass else []

        objects = fetch(cur, """
            select n.nspname as schema_name, c.relkind,
                   count(*) as object_count
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('public', 'crm', 'private')
              and c.relkind in ('r', 'p', 'v', 'm', 'f')
            group by n.nspname, c.relkind
            order by n.nspname, c.relkind
        """)
        functions = fetch(cur, """
            select n.nspname as schema_name, count(*) as function_count
            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'crm', 'private')
            group by n.nspname order by n.nspname
        """)
        policies = fetch(cur, """
            select schemaname, count(*) as policy_count
            from pg_policies
            where schemaname in ('public', 'crm', 'private')
            group by schemaname order by schemaname
        """)
        columns = fetch(cur, """
            select table_schema, table_name, count(*) as column_count
            from information_schema.columns
            where table_schema in ('public', 'crm', 'private')
            group by table_schema, table_name
            order by table_schema, table_name
        """)
        cron = fetch(cur, "select to_regclass('cron.job') as cron_job, to_regclass('cron.job_run_details') as cron_job_run_details")

        count_targets = {
            "clients_base": ("public", "clients_base"),
            "auth_users": ("auth", "users"),
            "client_users": ("public", "client_users"),
            "tenant_memberships": ("crm", "tenant_memberships"),
            "opportunities": ("crm", "opportunities"),
            "contacts": ("crm", "contacts"),
            "activities": ("crm", "activities"),
            "events_raw": ("public", "events_raw"),
            "events_normalized": ("public", "events_normalized"),
        }
        counts = {}
        for label, (schema, table) in count_targets.items():
            exists = one(cur, "select to_regclass(%s)", (f"{schema}.{table}",))
            counts[label] = {"relation": f"{schema}.{table}", "present": exists is not None,
                             "rows": one(cur, f"select count(*) from \"{schema}\".\"{table}\"") if exists else None}

        fixture = fetch(cur, """
            select t.id, t.name
            from crm.tenants t order by t.id
        """) if one(cur, "select to_regclass('crm.tenants')") else []

        result = {
            "target": {"ref": REF, "production_ref": PROD, "endpoint": env["PGHOST"],
                       "session": before, "after_set_role": after},
            "ledger": {"relation_present": ledger_regclass is not None, "rows": ledger,
                       "count": len(ledger)},
            "catalog": {"relations": objects, "functions": functions, "policies": policies,
                        "columns": columns, "cron": cron},
            "fixture_counts": counts,
            "fixture_tenants": fixture,
            "advance_migrations": ADVANCE_MIGRATIONS,
        }
        print(json.dumps(result, ensure_ascii=False, default=str, indent=2))
    finally:
        conn.rollback()
        conn.close()


if __name__ == "__main__":
    main()
