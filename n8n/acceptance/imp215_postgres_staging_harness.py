#!/usr/bin/env python3
"""IMP-215: prova real em staging; cria fixture Impuls e limpa ao final."""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
from pathlib import Path

import pg8000

STAGING_REF = "nfratueiutxnypbxfnmi"
PRODUCTION_REF = "mtxnwtqwfagjzkvgsncs"
IMPULS = "3ec294db-a64a-4420-9b4a-0d917f65d399"
RAW_ID = "61000000-0000-4000-8000-000000000215"
EVENT_ID = "71000000-0000-4000-8000-000000000215"
OUTBOX_ID = "81000000-0000-4000-8000-000000000215"


def connection_env() -> dict[str, str]:
    cli = os.environ.get("N8N_SUPABASE_CLI", r"C:\Users\caiop\AppData\Local\hermes\node\npx.cmd")
    result = subprocess.run(
        [cli, "supabase", "db", "dump", "--project-ref", STAGING_REF, "--schema", "public", "--dry-run"],
        cwd=Path(__file__).resolve().parents[2],
        capture_output=True,
        text=True,
        check=True,
    )
    values = {
        key: re.search(rf"export {key}=\"([^\"]*)\"", result.stdout).group(1)
        for key in ("PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE")
    }
    target = json.dumps(values)
    if STAGING_REF not in target or PRODUCTION_REF in target:
        raise RuntimeError("staging endpoint guard failed")
    return values


def connect(v: dict[str, str]):
    return pg8000.connect(
        user=v["PGUSER"], password=v["PGPASSWORD"], host=v["PGHOST"],
        port=int(v["PGPORT"]), database=v["PGDATABASE"], ssl_context=True,
    )


CLAIM_SQL = """
with candidates as (
  select co.id
  from public.conversion_outbox co
  join public.events_normalized en on en.id = co.normalized_event_id
  where en.source_system = 'impuls_crm'
    and en.client_id = %s::uuid
    and co.platform = 'meta'
    and co.status = 'pending'
    and co.next_attempt_at <= now()
    and co.attempts < 3
  order by co.created_at, co.id
  limit 1
  for update skip locked
), claimed as (
  update public.conversion_outbox co
     set status = 'processing', attempts = co.attempts + 1,
         next_attempt_at = now() + interval '30 minutes', updated_at = now()
    from candidates c where co.id = c.id
  returning co.id, co.attempts
)
select id, attempts from claimed;
"""


def main() -> None:
    v = connection_env()
    setup = connect(v)
    try:
        cur = setup.cursor()
        cur.execute("set role postgres")
        cur.execute(
            "insert into public.events_raw (id, source_system, event_type, location_id, payload, processing_status) "
            "values (%s::uuid, 'impuls_crm', 'stage_change', 'synthetic-impuls', %s::jsonb, 'processed') "
            "on conflict (id) do nothing",
            (RAW_ID, '{"synthetic":true,"imp215":true}'),
        )
        cur.execute(
            "insert into public.events_normalized (id, raw_event_id, client_id, ghl_location_id, ghl_location_name, "
            "client_name, event_code, event_name, event_datetime, source_system, normalization_status) "
            "values (%s::uuid, %s::uuid, %s::uuid, 'synthetic-impuls', 'Synthetic Impuls', 'Impuls', "
            "'ganho', 'Ganho', now(), 'impuls_crm', 'normalized') on conflict (id) do nothing",
            (EVENT_ID, RAW_ID, IMPULS),
        )
        cur.execute(
            "insert into public.conversion_outbox (id, normalized_event_id, ghl_location_id, event_code, platform, "
            "route, meta_event_name, payload, status, attempts, next_attempt_at) values "
            "(%s::uuid, %s::uuid, 'synthetic-impuls', 'ganho', 'meta', 'standard', 'Lead', %s::jsonb, 'pending', 0, now()) "
            "on conflict (id) do update set status='pending', attempts=0, next_attempt_at=now()",
            (OUTBOX_ID, EVENT_ID, '{"synthetic":true,"imp215":true}'),
        )
        setup.commit()

        results: list[tuple[str, list[tuple]]] = []
        lock = threading.Lock()

        def worker(name: str) -> None:
            conn = connect(v)
            try:
                c = conn.cursor(); c.execute("set role postgres"); c.execute("begin")
                c.execute(CLAIM_SQL, (IMPULS,))
                rows = c.fetchall()
                with lock:
                    results.append((name, rows))
                conn.commit()
            finally:
                conn.close()

        threads = [threading.Thread(target=worker, args=("claim-a",)), threading.Thread(target=worker, args=("claim-b",))]
        for t in threads: t.start()
        for t in threads: t.join()
        claimed = [rows for _, rows in results if rows]
        row = claimed[0][0] if len(claimed) == 1 else None
        if len(claimed) != 1 or str(row[0]) != OUTBOX_ID or row[1] != 1:
            raise AssertionError(f"concurrent claim gate failed: {results!r}")

        cur = setup.cursor()
        cur.execute("select status, attempts from public.conversion_outbox where id=%s::uuid", (OUTBOX_ID,))
        status, attempts = cur.fetchone()
        if (status, attempts) != ("processing", 1):
            raise AssertionError(f"claim readback failed: {(status, attempts)!r}")

        cur.execute("update public.conversion_outbox set status='sent' where id=%s::uuid and status='processing' and attempts=0 returning id", (OUTBOX_ID,))
        if cur.fetchall():
            raise AssertionError("stale closure unexpectedly updated the row")
        setup.commit()
        print(json.dumps({"status": "PASS", "claims": results, "readback": {"status": status, "attempts": attempts}, "stale_close_rows": 0}, default=str))
    finally:
        cur = setup.cursor()
        cur.execute("delete from public.conversion_outbox where id=%s::uuid", (OUTBOX_ID,))
        deleted_outbox = cur.rowcount
        cur.execute("delete from public.events_normalized where id=%s::uuid", (EVENT_ID,))
        deleted_events = cur.rowcount
        cur.execute("delete from public.events_raw where id=%s::uuid", (RAW_ID,))
        deleted_raw = cur.rowcount
        setup.commit()
        print(json.dumps({"cleanup_deleted": {"outbox": deleted_outbox, "events_normalized": deleted_events, "events_raw": deleted_raw}}))
        setup.close()


if __name__ == "__main__":
    main()
