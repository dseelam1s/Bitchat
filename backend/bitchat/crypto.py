"""
Pure-Python BIP340 Schnorr signature verification for secp256k1.
No native dependencies — works everywhere without compilation.

Verifies that auth requests are signed by the claimed pubkey,
proving the caller controls the corresponding private key.
"""
import hashlib
import json

# secp256k1 curve parameters
_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
_G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)


def _point_add(p1, p2):
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    if p1[0] == p2[0]:
        if p1[1] != p2[1]:
            return None
        lam = (3 * p1[0] * p1[0] * pow(2 * p1[1], _P - 2, _P)) % _P
    else:
        lam = ((p2[1] - p1[1]) * pow(p2[0] - p1[0], _P - 2, _P)) % _P
    x3 = (lam * lam - p1[0] - p2[0]) % _P
    return (x3, (lam * (p1[0] - x3) - p1[1]) % _P)


def _point_mul(point, n):
    result = None
    for i in range(256):
        if (n >> i) & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
    return result


def _tagged_hash(tag: str, data: bytes) -> bytes:
    tag_hash = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(tag_hash + tag_hash + data).digest()


def verify_schnorr(pubkey_hex: str, msg_hex: str, sig_hex: str) -> bool:
    """
    Verify a BIP340 Schnorr signature.

    Args:
        pubkey_hex: 32-byte x-only public key as hex (64 chars)
        msg_hex:    32-byte message (event id) as hex (64 chars)
        sig_hex:    64-byte signature as hex (128 chars)

    Returns:
        True if signature is valid.
    """
    try:
        if len(pubkey_hex) != 64 or len(msg_hex) != 64 or len(sig_hex) != 128:
            return False

        px = int(pubkey_hex, 16)
        msg = bytes.fromhex(msg_hex)
        sig = bytes.fromhex(sig_hex)

        r = int.from_bytes(sig[:32], 'big')
        s = int.from_bytes(sig[32:], 'big')

        if r >= _P or s >= _N:
            return False

        # Lift x to point with even y (BIP340)
        y_sq = (pow(px, 3, _P) + 7) % _P
        y = pow(y_sq, (_P + 1) // 4, _P)
        if pow(y, 2, _P) != y_sq:
            return False
        pub_point = (px, y if y % 2 == 0 else _P - y)

        e_input = r.to_bytes(32, 'big') + px.to_bytes(32, 'big') + msg
        e = int.from_bytes(_tagged_hash('BIP0340/challenge', e_input), 'big') % _N

        r_point = _point_add(_point_mul(_G, s), _point_mul(pub_point, _N - e))

        if r_point is None or r_point[1] % 2 != 0 or r_point[0] != r:
            return False

        return True
    except Exception:
        return False


def verify_nostr_event(event: dict) -> bool:
    """
    Verify a Nostr event's ID integrity and Schnorr signature.

    Checks:
    1. Computed event ID matches the provided ID
    2. Schnorr signature is valid for that ID and pubkey
    """
    try:
        serialized = json.dumps(
            [
                0,
                event['pubkey'],
                event['created_at'],
                event['kind'],
                event['tags'],
                event['content'],
            ],
            separators=(',', ':'),
            ensure_ascii=False,
        )
        computed_id = hashlib.sha256(serialized.encode('utf-8')).hexdigest()

        if computed_id != event['id']:
            return False

        return verify_schnorr(event['pubkey'], event['id'], event['sig'])
    except Exception:
        return False
