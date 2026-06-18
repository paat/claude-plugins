"""Minimal HS256 JWT encode/verify using only the standard library."""
import base64
import hashlib
import hmac
import json


def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _b64u_dec(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def encode(claims: dict, secret: bytes) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    seg = _b64u(json.dumps(header, separators=(",", ":")).encode()) + "." + \
        _b64u(json.dumps(claims, separators=(",", ":")).encode())
    sig = hmac.new(secret, seg.encode(), hashlib.sha256).digest()
    return seg + "." + _b64u(sig)


def decode(token: str, secret: bytes) -> dict:
    """Verify the HS256 signature (constant-time) and return the claims."""
    seg, _, sig_b64 = token.rpartition(".")
    if not seg or not sig_b64:
        raise ValueError("malformed token")
    expected = hmac.new(secret, seg.encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(expected, _b64u_dec(sig_b64)):
        raise ValueError("bad signature")
    _, _, payload_b64 = seg.partition(".")
    return json.loads(_b64u_dec(payload_b64))


def decode_unsafe(token: str) -> dict:
    """Parse claims WITHOUT verifying the signature. Used only by a seeded trap."""
    seg, _, _ = token.rpartition(".")
    _, _, payload_b64 = seg.partition(".")
    return json.loads(_b64u_dec(payload_b64))
