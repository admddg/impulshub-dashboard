#!/usr/bin/env python3
"""Runner do Head SO PARA STAGING (nfratueiutxnypbxfnmi). Aborta se o alvo for producao.
uso: stg.py commit|rollback arquivo.sql [arquivo2.sql ...]
Executa os arquivos numa unica transacao, statement a statement; imprime resultados de SELECT; em erro faz rollback."""
import importlib.util, json, re, subprocess, sys
from pathlib import Path
import pg8000

PROD = "mtxnwtqwfagjzkvgsncs"
REF = "nfratueiutxnypbxfnmi"
assert REF != PROD
CLI = "npx.cmd" if sys.platform == "win32" else "npx"
ROOT = str(Path(__file__).resolve().parents[1])
spec = importlib.util.spec_from_file_location("dbprova", Path(ROOT) / "scripts" / "db-prova.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

def conn_env():
    p = subprocess.run([CLI, "supabase", "db", "dump", "--project-ref", REF, "--schema", "public", "--dry-run"],
                       cwd=ROOT, capture_output=True, text=True, check=True)
    return {k: re.search(rf'export {k}="([^"]*)"', p.stdout).group(1)
            for k in ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE"]}

def main():
    mode, files = sys.argv[1], sys.argv[2:]
    assert mode in ("commit", "rollback")
    v = conn_env()
    assert PROD not in json.dumps({k: v[k] for k in ("PGHOST", "PGUSER")}), "ABORTA: alvo e producao"
    c = pg8000.connect(user=v["PGUSER"], password=v["PGPASSWORD"], host=v["PGHOST"], port=int(v["PGPORT"]),
                       database=v["PGDATABASE"], ssl_context=True)
    cur = c.cursor()
    cur.execute("set role postgres")
    n = 0
    try:
        for f in files:
            for s in mod.split_sql(Path(f).read_text(encoding="utf-8")):
                t = s.strip()
                low = re.sub(r"\s+", " ", t.lower())
                if not t or t.startswith("\\"):
                    continue
                if low in ("begin", "begin;", "commit", "commit;", "rollback", "rollback;"):
                    continue
                n += 1
                try:
                    cur.execute(t)
                except Exception as e:
                    info = e.args[0] if e.args and isinstance(e.args[0], dict) else {"M": str(e)}
                    print(f"ERRO {Path(f).name} #{n}: {info.get('C')} {info.get('M')} :: {re.sub(chr(10), ' ', t)[:140]}")
                    c.rollback(); c.close(); sys.exit(1)
                try:
                    rows = cur.fetchall()
                    if rows:
                        print(f"[{Path(f).name} #{n}]", json.dumps(rows, default=str, ensure_ascii=False)[:600])
                except Exception:
                    pass
        if mode == "commit":
            c.commit(); print(f"COMMIT ok ({n} statements) em {REF}")
        else:
            c.rollback(); print(f"ROLLBACK ok ({n} statements) em {REF}")
    finally:
        try: c.close()
        except Exception: pass

main()
