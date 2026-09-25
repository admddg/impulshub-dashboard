#!/usr/bin/env python3
"""Static regression lint for n8n expressions in IMP-215 workflows."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "workflows"
FILES = sorted(ROOT.glob("IMP-215-*.json"))
EXPRESSION_RE = re.compile(r"\{\{(.*?)\}\}", re.DOTALL)


def walk_strings(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from walk_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_strings(child)
    elif isinstance(value, str):
        yield value


def lint_workflow(path: Path) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    expressions = []
    for text in walk_strings(data):
        expressions.extend(EXPRESSION_RE.findall(text))

    for node in data.get("nodes", []):
        name = node.get("name", "")
        parameters = node.get("parameters", {})
        query = parameters.get("query", "")
        if name == "Normalize Dispatch Input":
            code = parameters.get("jsCode", "")
            required_markers = [
                "valid_conversion_outbox_uuid_required",
                "claimedAttempt",
                "? 0 : Number",
                "scheduled_claim_context_required",
            ]
            for marker in required_markers:
                if marker not in code:
                    errors.append(f"{name}: validation marker missing: {marker}")
        if name in {"Get Single Meta Outbox", "Get Single Google Outbox"}:
            select_match = re.search(r"\)\s*select\s+(.*?)\s+from\s+input", query, flags=re.IGNORECASE | re.DOTALL)
            select_list = select_match.group(1) if select_match else query
            aliases = re.findall(r"\bas\s+claimed_attempt\b", select_list, flags=re.IGNORECASE)
            if len(aliases) != 1:
                errors.append(f"{name}: expected exactly one claimed_attempt alias in SELECT list, got {len(aliases)}")
            if "String($json" in select_list or ".replaceAll(" in select_list:
                errors.append(f"{name}: dynamic String/replaceAll SQL interpolation remains in SELECT list")
            if "{{ $json.conversion_outbox_id }}::uuid" not in query:
                errors.append(f"{name}: UUID must be rendered as a validated typed value")
            if "NULLIF('{{ $json.conversion_outbox_id }}'" in query:
                errors.append(f"{name}: conversion_outbox_id remains inside quoted SQL interpolation")
            if "{{ $json.claimed_attempt }}" not in query:
                errors.append(f"{name}: normalized claimed_attempt expression missing")
            if "coalesce(cl.claimed_attempt, {{ $json.claimed_attempt }})" not in query:
                errors.append(f"{name}: claimed_attempt fallback is not SQL-safe")

    return errors


def main() -> int:
    if not FILES:
        print("FAIL no IMP-215 workflow JSON files found")
        return 1
    failures = []
    expression_count = 0
    for path in FILES:
        data = json.loads(path.read_text(encoding="utf-8"))
        expression_count += sum(1 for text in walk_strings(data) for _ in EXPRESSION_RE.findall(text))
        for error in lint_workflow(path):
            failures.append(f"{path.name}: {error}")
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print(f"PASS imp215_n8n_expression_lint workflows={len(FILES)} expressions={expression_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
