"""Reference CORRECT mock payment-webhook handler (Montonio-style HS256 JWT).

Each seeded trap in ../pytest/trap_*.py is a one-edit copy of this file with a single
invariant broken. The contract suite asserts this version is all-green.
"""
import json
import threading
import time  # SEEDED TRAP: needed for race-window sleep

import jwtmini

SECRET = b"test-secret"
TOLERANCE = 300
TERMINAL = {"PAID", "ABANDONED", "REFUNDED"}


class Store:
    def __init__(self):
        self.orders = {}        # ref -> {"status": str, "amount_cents": int}
        self.processed = set()  # event uuids already applied (durable dedupe)
        self.effects = []       # list of (ref, status) actually applied
        self._lock = threading.Lock()

    def create_order(self, ref, amount_cents):
        if ref in self.orders:                       # reference-uniqueness (fresh order)
            raise ValueError("duplicate merchantReference: %s" % ref)
        self.orders[ref] = {"status": "PENDING", "amount_cents": amount_cents}

    def paid_count(self, ref):
        return sum(1 for r, st in self.effects if r == ref and st == "PAID")


def build_grand_total(amount_cents):                 # money-minor-units: no float
    return "%d.%02d" % (amount_cents // 100, amount_cents % 100)


def make_webhook_token(uuid, ref, status, amount_cents, *,
                       secret=SECRET, now=1_700_000_000, iat=True):
    claims = {
        "accessKey": "ak",
        "uuid": uuid,
        "merchantReference": ref,
        "paymentStatus": status,
        "grandTotal": build_grand_total(amount_cents),
        "currency": "EUR",
        "exp": now + 600,
    }
    if iat:
        claims["iat"] = now
    return jwtmini.encode(claims, secret)


def handle_webhook(store, raw_body, *, now):
    body = json.loads(raw_body)
    token = body.get("orderToken", "")
    try:
        claims = jwtmini.decode(token, SECRET)       # webhook-authenticity (constant-time)
    except ValueError:
        return 401
    iat = claims.get("iat")
    if iat is None or abs(now - iat) > TOLERANCE:    # replay / recency window
        return 401
    ref = claims.get("merchantReference")
    status = claims.get("paymentStatus")             # status from VERIFIED token, not body
    if not ref or not status:                        # required claim shape
        return 400
    order = store.orders.get(ref)
    if order is None:
        return 404
    uuid = claims["uuid"]
    # SEEDED TRAP: lock removed — concurrent requests are no longer serialized
    if uuid in store.processed:                  # idempotent-effects
        return 200
    time.sleep(0.001)  # SEEDED TRAP: widen race window so concurrent duplicate applies twice
    if order["status"] in TERMINAL and status != order["status"]:
        store.processed.add(uuid)                # terminal-state-ordering: no downgrade
        return 200
    order["status"] = status                     # durability-before-ack: persist first
    store.effects.append((ref, status))
    store.processed.add(uuid)
    return 200
