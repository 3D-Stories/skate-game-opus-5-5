#!/usr/bin/env python3
"""Compares two Godot 4 .pck files (or exes with an embedded pck) entry by entry.

    python3 tests/pck_diff.py a.pck b.pck [--show-binary]    exit 0 if every entry is the same

Prints the entries only one side has and the entries whose bytes differ (by their MD5 and
their content). For a differing project.binary it also lists the settings that differ.
"""
import hashlib
import struct
import sys


def read_pck(path):
    data = open(path, "rb").read()
    base = data.rfind(b"GDPC") if not data.startswith(b"GDPC") else 0
    if base < 0:
        raise SystemExit("%s: no pck found" % path)
    if not data.startswith(b"GDPC"):
        # embedded: the last 12 bytes are <pck size u64><"GDPC">; the header starts before it
        size = struct.unpack("<Q", data[-12:-4])[0]
        base = len(data) - 12 - size
        assert data[base:base + 4] == b"GDPC", "embedded pck header not found"
    o = base + 4
    ver, maj, mi, pa, flags, file_base = struct.unpack("<IIIIIQ", data[o:o + 28])
    o += 28
    if ver >= 3:
        dir_ofs = struct.unpack("<Q", data[o:o + 8])[0]
        o = base + dir_ofs
    else:
        o += 16 * 4
    rel = bool(flags & 2)
    n = struct.unpack("<I", data[o:o + 4])[0]
    o += 4
    files = {}
    for _ in range(n):
        sl = struct.unpack("<I", data[o:o + 4])[0]
        o += 4
        name = data[o:o + sl].rstrip(b"\0").decode()
        o += sl
        ofs, size = struct.unpack("<QQ", data[o:o + 16])
        o += 16
        md5 = data[o:o + 16].hex()
        o += 16
        o += 4                                   # flags
        start = (base + file_base + ofs) if rel else (base + ofs) if ver < 3 else base + file_base + ofs
        files[name] = (md5, data[start:start + size])
    return (maj, mi, pa), files


def project_settings(blob):
    """Keys and raw value bytes of a project.binary ("ECFG", count, key/value pairs)."""
    assert blob[:4] == b"ECFG"
    n = struct.unpack("<I", blob[4:8])[0]
    o = 8
    out = {}
    for _ in range(n):
        kl = struct.unpack("<I", blob[o:o + 4])[0]
        o += 4
        k = blob[o:o + kl].decode()
        o += kl
        vl = struct.unpack("<I", blob[o:o + 4])[0]
        o += 4
        out[k] = blob[o:o + vl]
        o += vl
    return out


def main():
    a_path, b_path = sys.argv[1:3]
    va, a = read_pck(a_path)
    vb, b = read_pck(b_path)
    print("%s: Godot %d.%d.%d, %d entries" % (a_path, *va, len(a)))
    print("%s: Godot %d.%d.%d, %d entries" % (b_path, *vb, len(b)))
    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    changed = sorted(k for k in set(a) & set(b) if a[k][1] != b[k][1])
    for k in only_a:
        print("  only in A: %s (%d bytes)" % (k, len(a[k][1])))
    for k in only_b:
        print("  only in B: %s (%d bytes)" % (k, len(b[k][1])))
    for k in changed:
        print("  differs:   %s (%d -> %d bytes)" % (k, len(a[k][1]), len(b[k][1])))
        if k.endswith("project.binary"):
            pa, pb = project_settings(a[k][1]), project_settings(b[k][1])
            for s in sorted(set(pa) | set(pb)):
                if pa.get(s) != pb.get(s):
                    print("      setting %s: %s" % (s, "added" if s not in pa else "removed" if s not in pb else "changed"))
    same = len(set(a) & set(b)) - len(changed)
    print("identical entries: %d; only in A: %d; only in B: %d; different: %d" % (same, len(only_a), len(only_b), len(changed)))
    sys.exit(0 if not (only_a or only_b or changed) else 1)


if __name__ == "__main__":
    main()
