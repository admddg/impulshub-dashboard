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

def iter_psql_items(text):
    """Yield ('sql', statement) and supported psql directives in source order.

    split_sql cannot see that \\gset terminates the preceding query because psql
    accepts that directive without a SQL semicolon. Split the source at directive
    lines first, then use the repository SQL splitter for each SQL segment.
    """
    segment = []
    for line in text.splitlines(keepends=True):
        match = re.match(r"^\s*(\\(?:set|gset)\b.*)$", line.strip(), re.I)
        if match:
            for statement in mod.split_sql("".join(segment)):
                yield "sql", statement
            segment = []
            yield "directive", match.group(1).strip()
        else:
            segment.append(line)
    for statement in mod.split_sql("".join(segment)):
        yield "sql", statement


def substitute_psql_vars(sql, variables):
    """Implement psql's raw :name and SQL-quoted :'name' forms."""
    out, i = [], 0
    while i < len(sql):
        if sql.startswith("--", i):
            end = sql.find("\\n", i)
            end = len(sql) if end < 0 else end
            out.append(sql[i:end]); i = end; continue
        if sql.startswith("/*", i):
            end = sql.find("*/", i + 2)
            end = len(sql) if end < 0 else end + 2
            out.append(sql[i:end]); i = end; continue
        if sql[i] == "'":
            start = i; i += 1
            while i < len(sql):
                if sql[i] == "'":
                    if i + 1 < len(sql) and sql[i + 1] == "'": i += 2; continue
                    i += 1; break
                i += 1
            out.append(sql[start:i]); continue
        if sql[i] == '"':
            start = i; i += 1
            while i < len(sql):
                if sql[i] == '"':
                    if i + 1 < len(sql) and sql[i + 1] == '"': i += 2; continue
                    i += 1; break
                i += 1
            out.append(sql[start:i]); continue
        if sql.startswith("::", i):
            out.append("::"); i += 2; continue
        if sql[i] == ":" and i + 1 < len(sql) and sql[i + 1] != ":":
            quoted = i + 1 < len(sql) and sql[i + 1] == "'"
            start = i + 2 if quoted else i + 1
            end = start
            while end < len(sql) and (sql[end].isalnum() or sql[end] == "_"): end += 1
            if end > start and (not quoted or end < len(sql) and sql[end] == "'"):
                name = sql[start:end]
                if name not in variables:
                    raise KeyError(f"variável psql não definida: {name}")
                value = variables[name]
                if value is None:
                    replacement = "NULL" if quoted else ""
                elif quoted:
                    replacement = "'" + str(value).replace("'", "''") + "'"
                else:
                    replacement = str(value)
                out.append(replacement); i = end + (1 if quoted else 0); continue
        out.append(sql[i]); i += 1
    return "".join(out)


def apply_directive(directive, variables, last_result, filename, statement_number):
    parts = directive.split(None, 2)
    command = parts[0].lower()
    if command == "\\set":
        if len(parts) < 2:
            raise ValueError(f"{filename}: \\set exige nome")
        variables[parts[1]] = parts[2] if len(parts) == 3 else ""
        return
    if command == "\\gset":
        prefix = parts[1] if len(parts) == 2 else ""
        description, rows = last_result
        if description is None:
            raise ValueError(f"{filename} #{statement_number}: \\gset sem resultado de query")
        if len(rows) != 1:
            raise ValueError(f"{filename} #{statement_number}: \\gset esperava 1 linha, recebeu {len(rows)}")
        for column, value in zip(description, rows[0]):
            variables[prefix + column[0]] = "" if value is None else str(value)
        return
    raise ValueError(f"diretiva psql não suportada: {directive}")


def main():
    mode, files = sys.argv[1], sys.argv[2:]
    assert mode in ("commit", "rollback")
    v = conn_env()
    assert PROD not in json.dumps({k: v[k] for k in ("PGHOST", "PGUSER")}), "ABORTA: alvo e producao"
    c = pg8000.connect(user=v["PGUSER"], password=v["PGPASSWORD"], host=v["PGHOST"], port=int(v["PGPORT"]),
                       database=v["PGDATABASE"], ssl_context=True)
    cur = c.cursor()
    cur.execute("set role postgres")
    variables, n = {}, 0
    last_result = (None, [])
    try:
        for f in files:
            for kind, item in iter_psql_items(Path(f).read_text(encoding="utf-8")):
                if kind == "directive":
                    apply_directive(item, variables, last_result, Path(f).name, n)
                    continue
                t = substitute_psql_vars(item.strip(), variables)
                low = re.sub(r"\s+", " ", t.lower())
                if not t or low in ("begin", "begin;", "commit", "commit;", "rollback", "rollback;"):
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
                    last_result = (cur.description, rows)
                    if rows:
                        print(f"[{Path(f).name} #{n}]", json.dumps(rows, default=str, ensure_ascii=False)[:600])
                except Exception:
                    last_result = (cur.description, [])
        if mode == "commit":
            c.commit(); print(f"COMMIT ok ({n} statements) em {REF}")
        else:
            c.rollback(); print(f"ROLLBACK ok ({n} statements) em {REF}")
    finally:
        try: c.close()
        except Exception: pass


if __name__ == "__main__":
    main()
