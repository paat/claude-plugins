import importlib
import os
import threading

import pytest

H = importlib.import_module(os.environ.get("PCT_HANDLER", "handler"))
NOW = 1_700_000_000


def fresh():
    s = H.Store()
    s.create_order("REF-1", 2500)
    return s


def _wh(tok):
    return '{"orderToken": "%s"}' % tok


def test_money_decimal_boundary_no_float():
    assert H.build_grand_total(2500) == "25.00"
    assert H.build_grand_total(7) == "0.07"
    assert H.build_grand_total(1999) == "19.99"


def test_paid_marks_order():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    assert H.handle_webhook(s, _wh(tok), now=NOW) == 200
    assert s.orders["REF-1"]["status"] == "PAID"


def test_required_claim_missing_rejected():
    claims = {"accessKey": "ak", "uuid": "e1", "paymentStatus": "PAID",
              "exp": NOW + 600, "iat": NOW}  # no merchantReference
    tok = jwtmini_encode(claims)
    s = fresh()
    assert H.handle_webhook(s, _wh(tok), now=NOW) == 400


def test_duplicate_reference_rejected():
    s = fresh()
    with pytest.raises(Exception):
        s.create_order("REF-1", 999)


def test_forged_signature_rejected():
    s = fresh()
    bad = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW, secret=b"wrong")
    assert H.handle_webhook(s, _wh(bad), now=NOW) == 401
    assert s.orders["REF-1"]["status"] == "PENDING"


def test_status_taken_from_token_not_body():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "ABANDONED", 2500, now=NOW)
    body = '{"orderToken": "%s", "paymentStatus": "PAID"}' % tok
    H.handle_webhook(s, body, now=NOW)
    assert s.orders["REF-1"]["status"] == "ABANDONED"  # body's PAID must be ignored


def test_stale_timestamp_rejected():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW - 10_000)
    assert H.handle_webhook(s, _wh(tok), now=NOW) == 401
    assert s.orders["REF-1"]["status"] == "PENDING"


def test_replayed_webhook_idempotent():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    H.handle_webhook(s, _wh(tok), now=NOW)
    H.handle_webhook(s, _wh(tok), now=NOW)  # replay (same uuid)
    assert s.paid_count("REF-1") == 1


def test_terminal_state_not_downgraded():
    s = fresh()
    paid = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    H.handle_webhook(s, _wh(paid), now=NOW)
    aband = H.make_webhook_token("e2", "REF-1", "ABANDONED", 2500, now=NOW)
    H.handle_webhook(s, _wh(aband), now=NOW)
    assert s.orders["REF-1"]["status"] == "PAID"


def test_concurrent_duplicate_applies_once():
    s = fresh()
    tok = H.make_webhook_token("e1", "REF-1", "PAID", 2500, now=NOW)
    body = _wh(tok)
    barrier = threading.Barrier(8)

    def worker():
        barrier.wait()
        H.handle_webhook(s, body, now=NOW)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert s.paid_count("REF-1") == 1


def jwtmini_encode(claims):
    import jwtmini
    return jwtmini.encode(claims, H.SECRET)
