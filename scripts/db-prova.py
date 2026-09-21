#!/usr/bin/env python3
"""IMP-226 database proof harness. --dry-run is the only supported mode here."""
import argparse
import json
import re
import subprocess
from pathlib import Path

import pg8000

ROOT = Path(__file__).resolve().parents[1]
CLI = r"C:\Users\caiop\AppData\Local\hermes\node\npx.cmd"
PROJECT = "mtxnwtqwfagjzkvgsncs"
MIGRATION = ROOT / "supabase/migrations/20260928000002_imp226a_open_card_on_individual_conversation.sql"
ROLLBACK = ROOT / "supabase/migrations/20260928000002_imp226a_open_card_on_individual_conversation.rollback.sql"
APPLY = ROOT / "supabase/acceptance/APLICAR-imp226a.sql"

CASES = [
    "mensagem recebida, número novo, sem anúncio",
    "mensagem recebida com anúncio",
    "mensagem de grupo",
    "mensagem enviada por nós para número novo",
    "segunda mensagem com card aberto",
    "contato com oportunidade anterior ganha ou perdida",
    "lid e incompleta",
    "isolamento entre clientes",
    "conversion_outbox e events_normalized sem variação",
]

PLANNED_COLUMNS = {
    "public.stevo_events_raw": [
        "id", "client_id", "event_type", "event_timestamp", "received_at",
        "payload", "payload_hash", "parse_status",
    ],
    "crm.contacts": ["tenant_id", "full_name", "phone_normalized"],
    "crm.opportunities": [
        "tenant_id", "contact_id", "pipeline_version_id", "current_stage_id",
        "title", "status", "opened_at", "ctwa_clid", "conversion_source",
        "meta_ad_id", "source_url", "ad_title", "entry_point_conversion_source",
    ],
    "crm.processed_events": [
        "tenant_id", "raw_event_id", "source", "external_id", "payload_hash", "status",
    ],
    "crm.activities": [
        "tenant_id", "contact_id", "opportunity_id", "raw_event_id", "kind", "direction",
        "body", "provider_message_id", "sent_confirmed_at", "created_at",
    ],
}


def split_sql(text):
    statements, start, i = [], 0, 0
    quote = dollar = None
    line_comment = block_comment = False
    while i < len(text):
        if line_comment:
            if text[i] == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if text.startswith("*/", i):
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if quote:
            if text[i] == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                else:
                    quote = None
                    i += 1
            else:
                i += 1
            continue
        if dollar:
            if text.startswith(dollar, i):
                i += len(dollar)
                dollar = None
            else:
                i += 1
            continue
        if text.startswith("--", i):
            line_comment = True
            i += 2
            continue
        if text.startswith("/*", i):
            block_comment = True
            i += 2
            continue
        if text[i] == "'":
            quote = "'"
            i += 1
            continue
        if text[i] == "$":
            match = re.match(r"\$[A-Za-z_0-9]*\$", text[i:])
            if match:
                dollar = match.group(0)
                i += len(dollar)
                continue
        if text[i] == ";":
            statement = text[start : i + 1].strip()
            if statement and statement.lower() not in {"begin;", "commit;", "rollback;"}:
                statements.append(statement)
            start = i + 1
        i += 1
    statement = text[start:].strip()
    if statement and statement.lower() not in {"begin;", "commit;", "rollback;"}:
        statements.append(statement)
    return statements


def connection_env():
    probe = subprocess.run(
        [CLI, "supabase", "db", "dump", "--project-ref", PROJECT,
         "--schema", "crm,public,private", "--dry-run"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    return {
        key: re.search(rf'export {key}="([^"]*)"', probe.stdout).group(1)
        for key in ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE"]
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args()
    assert args.dry_run

    env = connection_env()
    conn = pg8000.connect(
        user=env["PGUSER"], password=env["PGPASSWORD"], host=env["PGHOST"],
        port=int(env["PGPORT"]), database=env["PGDATABASE"], ssl_context=True,
    )
    cur = conn.cursor()
    cur.execute("begin read only")
    try:
        cur.execute("select current_user, session_user")
        print(json.dumps({"before_set_role": cur.fetchone()}))
        cur.execute("set role postgres")
        cur.execute("select current_user, session_user")
        print(json.dumps({"after_set_role_postgres": cur.fetchone(), "set_role": "passed"}))

        for schema, table in [
            ("crm", "opportunities"), ("crm", "contacts"),
            ("crm", "activities"), ("crm", "processed_events"),
            ("public", "stevo_events_raw"),
        ]:
            cur.execute(
                "select count(*) from information_schema.columns "
                "where table_schema=%s and table_name=%s", (schema, table),
            )
            print(json.dumps({"table": f"{schema}.{table}", "column_count": cur.fetchone()[0]}))
            cur.execute(f"select count(*) from {schema}.{table}")
            print(json.dumps({"table": f"{schema}.{table}", "row_count_read_only": cur.fetchone()[0]}))

        for qualified, columns in PLANNED_COLUMNS.items():
            schema, table = qualified.split(".")
            cur.execute(
                "select column_name from information_schema.columns "
                "where table_schema=%s and table_name=%s", (schema, table),
            )
            available = {row[0] for row in cur.fetchall()}
            missing = sorted(set(columns) - available)
            print(json.dumps({"insert_columns": qualified, "missing": missing, "validated": not missing}))
            if missing:
                raise RuntimeError(f"missing columns for {qualified}: {missing}")

        for path in [MIGRATION, ROLLBACK, APPLY]:
            statements = split_sql(path.read_text(encoding="utf-8"))
            print(json.dumps({"file": str(path.relative_to(ROOT)), "statement_count_by_analysis": len(statements)}))

        for case in CASES:
            print(json.dumps({"seria_executado": case}, ensure_ascii=False))

        print(json.dumps({"dry_run": "passed", "writes": 0, "ddl": 0, "commit": 0}))
    finally:
        conn.rollback()
        conn.close()


if __name__ == "__main__":
    main()
