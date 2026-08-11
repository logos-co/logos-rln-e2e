#!/usr/bin/env python3
# Key helpers for the multi-node mix E2E. Pure-python (no external deps) so it
# runs on the host or in any container:
#   mixpub <privhex>     -> curve25519 mix public key hex (RFC7748 X25519, matches
#                           nim-libp2p public(priv))
#   peerpub <peerIdB58>  -> secp256k1 libp2p public key hex, decoded from the
#                           peerId (libp2p inlines secp256k1 pubkeys via the
#                           identity multihash)
import sys

# ---- base58 (btc alphabet) ----
_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

def b58decode(s: str) -> bytes:
    n = 0
    for c in s:
        n = n * 58 + _B58.index(c)
    full = n.to_bytes((n.bit_length() + 7) // 8, "big")
    pad = len(s) - len(s.lstrip("1"))
    return b"\x00" * pad + full

# ---- RFC 7748 X25519 ----
_P = 2 ** 255 - 19

def _clamp(k: bytes) -> int:
    k = bytearray(k)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    return int.from_bytes(k, "little")

def _x25519(scalar: int, u: int) -> int:
    x1 = u
    x2, z2, x3, z3 = 1, 0, u, 1
    swap = 0
    for t in range(254, -1, -1):
        kt = (scalar >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt
        A = (x2 + z2) % _P
        AA = (A * A) % _P
        B = (x2 - z2) % _P
        BB = (B * B) % _P
        E = (AA - BB) % _P
        C = (x3 + z3) % _P
        D = (x3 - z3) % _P
        DA = (D * A) % _P
        CB = (C * B) % _P
        x3 = pow((DA + CB) % _P, 2, _P)
        z3 = (x1 * pow((DA - CB) % _P, 2, _P)) % _P
        x2 = (AA * BB) % _P
        z2 = (E * ((AA + (121665 * E) % _P) % _P)) % _P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, _P - 2, _P)) % _P

def mixpub(privhex: str) -> str:
    priv = bytes.fromhex(privhex)
    pub = _x25519(_clamp(priv), 9)
    return pub.to_bytes(32, "little").hex()

def peerpub(peerid: str) -> str:
    raw = b58decode(peerid)
    # identity multihash: 0x00 <len> <PublicKey protobuf>
    assert raw[0] == 0x00, "peerId is not an identity multihash (key not inlined)"
    ln = raw[1]
    pb = raw[2:2 + ln]
    # PublicKey protobuf: field1 = KeyType (varint), field2 = Data (bytes)
    i = 0
    keytype = None
    data = None
    while i < len(pb):
        tag = pb[i]; i += 1
        field = tag >> 3
        wt = tag & 7
        if wt == 0:  # varint
            v = 0; shift = 0
            while True:
                b = pb[i]; i += 1
                v |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            if field == 1:
                keytype = v
        elif wt == 2:  # length-delimited
            ln2 = pb[i]; i += 1
            chunk = pb[i:i + ln2]; i += ln2
            if field == 2:
                data = chunk
    assert keytype == 2, f"expected Secp256k1 key type (2), got {keytype}"
    assert data is not None and len(data) == 33, f"bad secp256k1 key len {len(data) if data else None}"
    return data.hex()

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "mixpub":
        print(mixpub(sys.argv[2]))
    elif cmd == "peerpub":
        print(peerpub(sys.argv[2]))
    else:
        sys.exit("usage: keys.py mixpub <privhex> | peerpub <peerIdB58>")
