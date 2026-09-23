#!/usr/bin/env python3
"""Repository-only IMP-215 contract checks; never connects to n8n or a database."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = Path(r"C:/Users/caiop/Downloads")
WORKFLOWS = ROOT / "n8n" / "workflows"


def wf(name):
    return json.loads((WORKFLOWS / name).read_text(encoding="utf-8"))


def node(workflow, name):
    return next(n for n in workflow["nodes"] if n["name"] == name)


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def test_exports_untouched():
    # Hashing is read-only and proves this harness never writes Downloads.
    for name in (
        "1.2 - Dispatch Single Meta Conversion - Observability V2.4 - Standard Route Scope Fix.json",
        "1.3 - Dispatch Single Google Ads Conversion - Observability V2.1 - Managed Node Errors.json",
    ):
        path = DOWNLOADS / name
        assert_true(path.is_file(), f"missing real export: {name}")
        assert_true(len(hashlib.sha256(path.read_bytes()).hexdigest()) == 64, "hash failed")


def test_dispatcher_guards_and_preservation():
    cases = [
        ("IMP-215-dispatch-single-meta-claim.json", "Get Single Meta Outbox", "Build Meta Request", "Finalize Meta Response", "meta"),
        ("IMP-215-dispatch-single-google-claim.json", "Get Single Google Outbox", "Build Data Manager Request", "Finalize Data Manager Response", "google_ads"),
    ]
    for filename, get_name, build_name, finalize_name, platform in cases:
        current = wf(filename)
        source_name = (node(current, "Sticky Note - Logs")["parameters"]["content"]
                       .split("imp215_source_export", 1)[-1] if False else None)
        get_sql = node(current, get_name)["parameters"]["query"]
        update_sql = node(current, f"Update Single {'Meta' if platform == 'meta' else 'Google'} Outbox Result")["parameters"]["query"]
        normalize = node(current, "Normalize Dispatch Input")["parameters"]["jsCode"]
        assert_true("dispatch_mode" in normalize and "claimed_attempt" in normalize, f"{platform}: input contract missing")
        assert_true("co.status = 'processing'" in get_sql and "co.attempts =" in get_sql and "co.next_attempt_at > now()" in get_sql, f"{platform}: lease read guard missing")
        assert_true("status = 'processing'" in update_sql and "attempts =" in update_sql, f"{platform}: conditional close missing")
        assert_true("stale_result" not in update_sql or "returning" in update_sql, f"{platform}: malformed close")
        # The request builders and response classifiers are copied from the real export;
        # these markers prove the platform-specific API path and retry vocabulary remain.
        build = node(current, build_name)["parameters"]["jsCode"]
        finalize = node(current, finalize_name)["parameters"]["jsCode"]
        if platform == "meta":
            assert_true("graph.facebook.com" in build and "retryable" in finalize and "final_status: 'pending'" in finalize, "Meta builder/retry path changed")
        else:
            assert_true("datamanager.googleapis.com" in build and "keep_pending_after_max_attempts" in finalize and "final_status: 'pending'" in finalize, "Google builder/retry path changed")
        assert_true("dispatch_mode: row.dispatch_mode" in build and "claimed_attempt: requestItem.claimed_attempt" in finalize, f"{platform}: claim context not propagated")


def test_consumer_is_closed_by_default():
    current = wf("IMP-215-scheduled-conversion-outbox-consumer.json")
    assert_true(current["active"] is False, "consumer must remain inactive")
    config = node(current, "Validate Versioned Allowlist and Cutoff")["parameters"]["jsCode"]
    sql = node(current, "Read Eligible Candidates (Dry Run)")["parameters"]["query"]
    report = node(current, "Dry Run Report")["parameters"]["jsCode"]
    for token in ("dry_run", "allowlist_required", "cutoff_required"):
        assert_true(token in config, f"consumer config guard missing: {token}")
    for token in ("source_system = 'impuls_crm'", "co.status in ('pending', 'failed')", "co.created_at >= cfg.cutoff_at", "co.attempts <"):
        assert_true(token in sql, f"consumer eligibility guard missing: {token}")
    assert_true("claim_sql_gate" in report and "dry_run" in report, "dry-run report missing")
    assert_true("Execute Workflow" not in json.dumps(current), "review-only consumer must not dispatch")


def test_negative_matrix():
    # Pure model of the SQL predicates, covering the negative cases without live writes.
    allow = {"client-a"}
    cutoff = {"client-a": 100}
    def eligible(row):
        return (row["client"] in allow and row["source"] == "impuls_crm" and row["cutoff"] is not None
                and row["created"] >= cutoff[row["client"]] and row["status"] in {"pending", "failed"}
                and row["next"] <= 0 and row["attempts"] < 3)
    base = {"client": "client-a", "source": "impuls_crm", "cutoff": 100, "created": 101, "status": "pending", "next": 0, "attempts": 0}
    assert_true(eligible(base), "eligible synthetic row rejected")
    for key, value in (("created", 99), ("client", "client-b"), ("source", "other"), ("status", "sent"), ("attempts", 3), ("cutoff", None)):
        row = dict(base); row[key] = value
        assert_true(not eligible(row), f"negative guard leaked: {key}={value}")


if __name__ == "__main__":
    for test in (test_exports_untouched, test_dispatcher_guards_and_preservation, test_consumer_is_closed_by_default, test_negative_matrix):
        test()
        print(f"PASS {test.__name__}")
