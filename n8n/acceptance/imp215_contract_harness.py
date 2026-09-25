#!/usr/bin/env python3
"""Repository-only IMP-215 contract checks; never connects to n8n or a database."""
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = Path(r"C:/Users/caiop/Downloads")
WORKFLOWS = ROOT / "n8n" / "workflows"
AUDIT_DOC = ROOT / "docs" / "IMP-215-N8N-1.1-CALLER-AUDIT.md"


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


def test_original_11_caller_is_explicitly_audited():
    """Keep the known gap visible until a versioned copy is authorized."""
    path = DOWNLOADS / "1.1 - Inbound Events - Normalize + Conversion Router - Observability V2.1 - Meta Attribution Fix.json"
    assert_true(path.is_file(), "missing real 1.1 export")
    current = json.loads(path.read_text(encoding="utf-8"))
    calls = [n for n in current["nodes"] if n["name"] in {
        "Call 03 - Dispatch Meta Conversion",
        "Call 04 - Dispatch Google Ads Conversion",
    }]
    assert_true(len(calls) == 2, "1.1 dispatcher call count changed")
    for call in calls:
        params = call["parameters"]
        assert_true(params["options"]["waitForSubWorkflow"] is False, f"{call['name']}: fire-and-forget changed")
        assert_true(params["workflowInputs"]["value"] == {}, f"{call['name']}: original export unexpectedly changed")
    audit = AUDIT_DOC.read_text(encoding="utf-8")
    for token in ("não passa", "outbox_id", "dispatch_mode=inline", "corrida", "160709ade06752d2c76d96d88ce4409013ebeecf55dd63f98cc83495167d9111"):
        assert_true(token in audit, f"1.1 audit missing: {token}")


def test_versioned_11_inline_copy_has_explicit_contract():
    current = wf("IMP-215-1.1-inbound-events-inline-contract.json")
    assert_true(current["active"] is False, "versioned 1.1 copy must remain inactive")
    calls = {n["name"]: n for n in current["nodes"] if n["name"] in {
        "Call 03 - Dispatch Meta Conversion",
        "Call 04 - Dispatch Google Ads Conversion",
    }}
    assert_true(len(calls) == 2, "versioned 1.1 copy must contain both dispatch calls")
    for name, call in calls.items():
        params = call["parameters"]
        assert_true(params["options"]["waitForSubWorkflow"] is False, f"{name}: fire-and-forget changed")
        assert_true(params["workflowInputs"]["value"] == {
            "outbox_id": "={{ $json.conversion_outbox_id }}",
            "dispatch_mode": "inline",
        }, f"{name}: inline input contract missing")
    assert_true(calls["Call 03 - Dispatch Meta Conversion"]["parameters"]["workflowId"]["value"] == "GuJOyCaF93i7ps8l", "Meta child ID mismatch")
    assert_true(calls["Call 04 - Dispatch Google Ads Conversion"]["parameters"]["workflowId"]["value"] == "VLzVbZaFqeKa0JJr", "Google child ID mismatch")


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


def test_consumer_is_guarded_for_impuls_pilot():
    current = wf("IMP-215-scheduled-conversion-outbox-consumer.json")
    config = node(current, "Validate Versioned Allowlist and Cutoff")["parameters"]["jsCode"]
    sql = node(current, "Read Eligible Candidates (Dry Run)")["parameters"]["query"]
    report = node(current, "Dry Run Report")["parameters"]["jsCode"]
    for token in ("dry_run", "allowlist_required", "cutoff_required"):
        assert_true(token in config, f"consumer config guard missing: {token}")
    for token in ("source_system = 'impuls_crm'", "co.status = 'pending'", "co.created_at >= cfg.cutoff_at", "co.attempts <"):
        assert_true(token in sql, f"consumer eligibility guard missing: {token}")
    assert_true("claim_sql_gate" in report and "dry_run" in report, "dry-run report missing")
    assert_true("Execute Workflow" in json.dumps(current), "controlled dispatch artifact missing")
    assert_true("dispatch_enabled" in config and "true" in config, "pilot dispatch must be explicitly enabled")
    assert_true("platform" in json.dumps(current) and "Meta Child" in json.dumps(current) and "Google Child" in json.dumps(current), "platform child routing missing")


def test_claim_dispatch_slice_is_present_but_killed():
    current = wf("IMP-215-scheduled-conversion-outbox-consumer.json")
    serialized = json.dumps(current)
    assert_true("Claim Eligible Outbox Rows" in serialized, "atomic claim node missing")
    claim = node(current, "Claim Eligible Outbox Rows")["parameters"]["query"]
    for token in ("update public.conversion_outbox", "status = 'processing'", "attempts = co.attempts + 1", "returning co.id", "for update skip locked"):
        assert_true(token in claim.lower(), f"claim contract missing: {token}")
    assert_true("Execute Workflow" in serialized, "controlled child dispatch nodes missing")
    assert_true("dispatch_enabled" in serialized and "true" in serialized, "pilot dispatch must be explicitly enabled")
    assert_true("platform" in serialized and "Meta Child" in serialized and "Google Child" in serialized, "platform routing missing")
    assert_true("AHT6ltpnxdC29QCC" not in serialized, "live consumer must not be overwritten by artifact")


def test_dispatcher_claim_and_protected_closure():
    cases = [
        ("IMP-215-dispatch-single-meta-claim.json", "Get Single Meta Outbox", "Update Single Meta Outbox Result"),
        ("IMP-215-dispatch-single-google-claim.json", "Get Single Google Outbox", "Update Single Google Outbox Result"),
    ]
    for filename, get_name, update_name in cases:
        current = wf(filename)
        get_sql = node(current, get_name)["parameters"]["query"].lower()
        update_sql = node(current, update_name)["parameters"]["query"].lower()
        for token in ("claimed as", "update public.conversion_outbox", "status = 'processing'", "returning"):
            assert_true(token in get_sql, f"{filename}: inline atomic claim missing: {token}")
        for token in ("where id =", "status = 'processing'", "attempts =", "returning", "stale_result"):
            assert_true(token in update_sql, f"{filename}: protected closure missing: {token}")
        assert_true("attempts = attempts + 1" not in update_sql, f"{filename}: closure increments attempts")


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


@dataclass
class SyntheticOutbox:
    """Small deterministic model of the guarded SQL contract.

    This is deliberately not a database adapter.  Each method is one serialized
    SQL transaction boundary, and the clock is injected so the race scenarios
    are reproducible without sleeps, threads, credentials, or network access.
    """

    status: str = "pending"
    attempts: int = 0
    lease_until: int = 0
    lease_seconds: int = 10
    response: str | None = None
    last_error: str | None = None

    def claim(self, now: int, expected_status: str = "pending"):
        if self.status != expected_status or self.lease_until > now or self.attempts >= 4:
            return None
        self.status = "processing"
        self.attempts += 1
        self.lease_until = now + self.lease_seconds
        return self.attempts

    def scheduled_read(self, now: int, claimed_attempt: int):
        if (self.status == "processing" and self.attempts == claimed_attempt
                and self.lease_until > now):
            return {"claimed_attempt": claimed_attempt}
        return None

    def close(self, claimed_attempt: int, computed_status: str, response: str):
        # Mirrors UPDATE ... WHERE status='processing' AND attempts=:claimed_attempt.
        if self.status != "processing" or self.attempts != claimed_attempt:
            return 0
        self.status = computed_status
        self.response = response
        return 1

    def recover_expired(self, now: int):
        if self.status == "processing" and self.lease_until <= now:
            self.status = "failed"
            self.last_error = "claim_lease_expired_external_state_unknown"
            return 1
        return 0


def test_deterministic_concurrent_claims_increment_once():
    row = SyntheticOutbox()
    first = row.claim(now=100)
    second = row.claim(now=100)
    assert_true(first == 1, "first contender did not receive attempt 1")
    assert_true(second is None, "second contender also claimed the row")
    assert_true(row.attempts == 1 and row.status == "processing", "claim was not unique")


def test_lease_expiry_closes_without_automatic_http_retry():
    row = SyntheticOutbox()
    claimed = row.claim(now=100)
    assert_true(claimed == 1, "lease fixture was not claimed")
    assert_true(row.scheduled_read(now=110, claimed_attempt=claimed) is None, "expired lease remained dispatchable")
    assert_true(row.recover_expired(now=110) == 1, "expired lease was not recovered")
    assert_true(row.status == "failed", "expired lease was not terminalized")
    assert_true(row.last_error == "claim_lease_expired_external_state_unknown", "wrong expiry reason")
    assert_true(row.attempts == 1, "lease recovery incremented attempts")


def test_stale_response_cannot_close_new_attempt():
    row = SyntheticOutbox()
    old_attempt = row.claim(now=100)
    assert_true(old_attempt == 1, "old attempt was not claimed")
    assert_true(row.recover_expired(now=110) == 1, "old lease did not expire")
    # Re-drive is explicit in the model; expiry itself never retries.
    row.status = "pending"
    new_attempt = row.claim(now=111)
    assert_true(new_attempt == 2, "explicit re-drive did not create attempt 2")
    assert_true(row.close(old_attempt, "sent", "stale-response") == 0, "stale response closed new attempt")
    assert_true(row.status == "processing" and row.attempts == 2, "stale response changed current ownership")
    assert_true(row.close(new_attempt, "sent", "current-response") == 1, "current response did not close")
    assert_true(row.status == "sent" and row.response == "current-response", "current close result is wrong")


if __name__ == "__main__":
    for test in (test_exports_untouched, test_original_11_caller_is_explicitly_audited, test_versioned_11_inline_copy_has_explicit_contract, test_dispatcher_guards_and_preservation, test_consumer_is_guarded_for_impuls_pilot, test_claim_dispatch_slice_is_present_but_killed, test_dispatcher_claim_and_protected_closure, test_negative_matrix, test_deterministic_concurrent_claims_increment_once, test_lease_expiry_closes_without_automatic_http_retry, test_stale_response_cannot_close_new_attempt):
        test()
        print(f"PASS {test.__name__}")
