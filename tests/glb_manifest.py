"""Manifest of the exported assets, to prove two builds are the same (live vs headless).

    python3 tests/glb_manifest.py out.json [assets_dir]
    python3 tests/glb_manifest.py --diff a.json b.json

For every GLB: node tree, meshes (per primitive: vertex/index counts, attribute names,
material, position bounds), skins, materials and their textures, animations (channels,
duration), and a SHA-256 of every accessor's bytes and every embedded image. Also hashes
park_data.json and any loose textures next to the GLBs. Pure Python (no Blender needed).
"""
import hashlib
import json
import os
import struct
import sys


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    magic, version, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67, f"{path}: not a GLB"
    off, js, binc = 12, None, b""
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            js = json.loads(chunk.decode("utf-8"))
        elif ctype == 0x004E4942:
            binc = chunk
        off += 8 + clen
    return js, binc


def view_bytes(js, binc, vi):
    bv = js["bufferViews"][vi]
    o = bv.get("byteOffset", 0)
    return binc[o:o + bv["byteLength"]]


def accessor_hash(js, binc, ai):
    acc = js["accessors"][ai]
    if "bufferView" not in acc:
        return "sparse-or-empty"
    raw = view_bytes(js, binc, acc["bufferView"])
    o = acc.get("byteOffset", 0)
    return hashlib.sha256(raw[o:] if o else raw).hexdigest()[:16]


def manifest_glb(path):
    js, binc = read_glb(path)
    nodes = js.get("nodes", [])
    out = {"file": os.path.basename(path), "bytes": os.path.getsize(path),
           "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]}
    out["nodes"] = sorted((n.get("name", ""), js["meshes"][n["mesh"]].get("name", "") if "mesh" in n else "",
                           len(n.get("children", []))) for n in nodes)
    meshes = []
    for m in js.get("meshes", []):
        prims = []
        for p in m["primitives"]:
            pos = js["accessors"][p["attributes"]["POSITION"]]
            prims.append({
                "verts": pos["count"],
                "indices": js["accessors"][p["indices"]]["count"] if "indices" in p else 0,
                "attributes": sorted(p["attributes"]),
                "material": js["materials"][p["material"]].get("name", "") if "material" in p else "",
                "min": [round(v, 4) for v in pos.get("min", [])], "max": [round(v, 4) for v in pos.get("max", [])],
                "hash": dict({k: accessor_hash(js, binc, a) for k, a in sorted(p["attributes"].items())},
                             **({"indices": accessor_hash(js, binc, p["indices"])} if "indices" in p else {})),
                "targets": len(p.get("targets", [])),
            })
        meshes.append({"name": m.get("name", ""), "primitives": prims})
    out["meshes"] = sorted(meshes, key=lambda m: m["name"])
    out["skins"] = [{"name": s.get("name", ""), "joints": len(s["joints"]),
                     "ibm": accessor_hash(js, binc, s["inverseBindMatrices"]) if "inverseBindMatrices" in s else ""}
                    for s in js.get("skins", [])]
    mats = []
    for m in js.get("materials", []):
        pbr = m.get("pbrMetallicRoughness", {})
        tex = {k: v["index"] for k, v in list(pbr.items()) + list(m.items()) if isinstance(v, dict) and "index" in v}
        mats.append({"name": m.get("name", ""), "textures": sorted(tex), "alpha": m.get("alphaMode", "OPAQUE"),
                     "double_sided": m.get("doubleSided", False)})
    out["materials"] = sorted(mats, key=lambda m: m["name"])
    imgs = []
    for im in js.get("images", []):
        h = hashlib.sha256(view_bytes(js, binc, im["bufferView"])).hexdigest()[:16] if "bufferView" in im else im.get("uri", "")
        imgs.append({"name": im.get("name", ""), "mime": im.get("mimeType", ""), "hash": h})
    out["images"] = sorted(imgs, key=lambda i: i["name"])
    anims = []
    for a in js.get("animations", []):
        tmax = 0.0
        for s in a["samplers"]:
            tmax = max(tmax, max(js["accessors"][s["input"]].get("max", [0.0])))
        h = hashlib.sha256("".join(accessor_hash(js, binc, s["input"]) + accessor_hash(js, binc, s["output"])
                                   for s in a["samplers"]).encode()).hexdigest()[:16]
        anims.append({"name": a.get("name", ""), "channels": len(a["channels"]), "duration": round(tmax, 4), "hash": h})
    out["animations"] = sorted(anims, key=lambda a: a["name"])
    return out


BLENDER_IMAGES = {"park_lightmap.png"}   # loose images written by the Blender build (the rest are Godot extractions)


def manifest_dir(d):
    res = {}
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        if f.endswith(".glb"):
            res[f] = manifest_glb(p)
        elif f.endswith(".json") or f in BLENDER_IMAGES:
            res[f] = {"sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()[:16], "bytes": os.path.getsize(p)}
    return res


def diff(a, b, path=""):
    """List of human-readable differences between two manifests."""
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{path}/{k}: only in {'b' if k not in a else 'a'}")
            else:
                out += diff(a[k], b[k], f"{path}/{k}")
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}: {len(a)} vs {len(b)} items")
        for i, (x, y) in enumerate(zip(a, b)):
            out += diff(x, y, f"{path}[{i}]")
    elif a != b:
        out.append(f"{path}: {a!r} != {b!r}")
    return out


def floats(js, binc, ai):
    acc = js["accessors"][ai]
    if acc.get("componentType") != 5126 or "bufferView" not in acc:
        return None
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[acc["type"]] * acc["count"]
    raw = view_bytes(js, binc, acc["bufferView"])
    o = acc.get("byteOffset", 0)
    stride = js["bufferViews"][acc["bufferView"]].get("byteStride")
    if stride:
        return None
    return struct.unpack_from(f"<{n}f", raw, o)


def deep(glb_a, glb_b):
    """Max absolute difference of every float vertex attribute, per mesh (same topology)."""
    ja, ba = read_glb(glb_a)
    jb, bb = read_glb(glb_b)
    rows = []
    for ma, mb in zip(ja["meshes"], jb["meshes"]):
        for pa, pb in zip(ma["primitives"], mb["primitives"]):
            for k in sorted(pa["attributes"]):
                fa, fb = floats(ja, ba, pa["attributes"][k]), floats(jb, bb, pb["attributes"][k])
                if fa is None or fb is None or len(fa) != len(fb):
                    continue
                m = max((abs(x - y) for x, y in zip(fa, fb)), default=0.0)
                if m > 0:
                    rows.append((ma.get("name", ""), k, m))
    return rows


def triangle_set(path, mesh_name):
    js, b = read_glb(path)
    out = []
    for m in js["meshes"]:
        if m.get("name", "") != mesh_name:
            continue
        for p in m["primitives"]:
            acc = js["accessors"][p["indices"]]
            raw = view_bytes(js, b, acc["bufferView"])
            fmt = {5121: "B", 5123: "H", 5125: "I"}[acc["componentType"]]
            idx = struct.unpack_from(f"<{acc['count']}{fmt}", raw, acc.get("byteOffset", 0))
            out.append(sorted(tuple(sorted(idx[i:i + 3])) for i in range(0, len(idx), 3)))
    return out


def embedded_image_diff(glb_a, glb_b, name):
    import io
    from PIL import Image, ImageChops

    def load(path):
        js, b = read_glb(path)
        for im in js.get("images", []):
            if im.get("name") == name:
                return Image.open(io.BytesIO(view_bytes(js, b, im["bufferView"]))).convert("RGBA")
    ia, ib = load(glb_a), load(glb_b)
    if ia is None or ib is None or ia.size != ib.size:
        return -1, 1.0, 255
    bands = ImageChops.difference(ia, ib).split()
    m = ImageChops.lighter(ImageChops.lighter(bands[0], bands[1]), ImageChops.lighter(bands[2], bands[3]))
    h = m.histogram()
    n = sum(h[1:])
    return n, n / (ia.size[0] * ia.size[1]), (max(i for i, c in enumerate(h) if c) if n else 0)


def check(dir_a, dir_b, label_a="live", label_b="headless"):
    """PASS/FAIL lines: are the two builds the same asset set?"""
    A, B = manifest_dir(dir_a), manifest_dir(dir_b)
    lines, ok_all = [], True
    for f in sorted(set(A) | set(B)):
        if f not in A or f not in B:
            lines.append(f"FAIL  {f}: missing from the {label_a if f not in A else label_b} build"); ok_all = False
            continue
        if A[f].get("sha256") == B[f].get("sha256"):
            lines.append(f"PASS  {f}: byte-identical ({A[f]['bytes']} bytes)")
            continue
        if f in BLENDER_IMAGES:
            # a GPU path-traced bake is not bit-exact run to run: compare texels
            from PIL import Image, ImageChops
            ia = Image.open(os.path.join(dir_a, f)).convert("RGB")
            ib = Image.open(os.path.join(dir_b, f)).convert("RGB")
            if ia.size != ib.size:
                lines.append(f"FAIL  {f}: size {ia.size} vs {ib.size}"); ok_all = False
                continue
            r, g, b = ImageChops.difference(ia, ib).split()
            hist = ImageChops.lighter(ImageChops.lighter(r, g), b).histogram()   # max channel difference
            n_diff = sum(hist[1:]); frac = n_diff / (ia.size[0] * ia.size[1])
            worst = max(i for i, c in enumerate(hist) if c) if n_diff else 0
            ok = worst <= 4 and frac <= 0.002
            ok_all &= ok
            lines.append(f"{'PASS' if ok else 'FAIL'}  {f}: {n_diff} of {ia.size[0] * ia.size[1]} texels differ "
                         f"({frac * 100:.3f}%), max {worst}/255 - GPU path-tracing noise level (limit 4/255 on 0.2%)")
            continue
        d = [x for x in diff(A[f], B[f]) if not x.startswith("/sha256") and not x.startswith("/bytes")]
        idx_only = [x for x in d if "/hash/indices" in x]
        img_only = [x for x in d if x.startswith("/images[") and x.split("]/")[1].startswith("hash")]
        other = [x for x in d if x not in idx_only and x not in img_only]
        img_notes = []
        for x in img_only:
            ii = int(x.split("/images[")[1].split("]")[0])
            name = A[f]["images"][ii]["name"]
            n_diff, frac, worst = embedded_image_diff(os.path.join(dir_a, f), os.path.join(dir_b, f), name)
            if worst <= 4 and frac <= 0.002:
                img_notes.append(f"texture '{name}' within GPU render noise ({n_diff} px, {frac * 100:.3f}%, max {worst}/255)")
            else:
                other.append(f"texture '{name}': {n_diff} px differ ({frac * 100:.3f}%), max {worst}/255")
        same_tris = True
        for x in idx_only:
            mi = int(x.split("/meshes[")[1].split("]")[0])
            name = A[f]["meshes"][mi]["name"]
            same_tris &= triangle_set(os.path.join(dir_a, f), name) == triangle_set(os.path.join(dir_b, f), name)
        if not other and same_tris:
            notes = ([f"{len(idx_only)} mesh(es) list the same triangles in a different order"] if idx_only else []) + img_notes
            lines.append(f"PASS  {f}: every node, mesh, vertex attribute value, skin, material and animation identical"
                         + ("; " + "; ".join(notes) if notes else ""))
        else:
            ok_all = False
            lines.append(f"FAIL  {f}: {len(other)} differences, e.g. {other[:3]}")
    return ok_all, lines


if __name__ == "__main__":
    if sys.argv[1] == "--check":
        ok, lines = check(sys.argv[2], sys.argv[3])
        print("\n".join(lines))
        sys.exit(0 if ok else 1)
    if sys.argv[1] == "--deep":
        for name, k, m in deep(sys.argv[2], sys.argv[3]):
            print(f"{name:14s} {k:10s} max |diff| = {m:.3g}" + ("  (metres)" if k == "POSITION" else ""))
        sys.exit(0)
    if sys.argv[1] == "--diff":
        A, B = (json.load(open(p)) for p in sys.argv[2:4])
        d = diff(A, B)
        glbs = sorted(k for k in A if k.endswith(".glb"))
        for g in glbs:
            same = A[g].get("sha256") == B.get(g, {}).get("sha256")
            print(f"{g}: {'byte-identical' if same else 'differs'}  ({A[g]['bytes']} / {B.get(g, {}).get('bytes')} bytes)")
        print(f"{len(d)} structural/data differences")
        for line in d[:200]:
            print("  " + line)
        sys.exit(0 if not d else 1)
    out = sys.argv[1]
    d = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")
    json.dump(manifest_dir(d), open(out, "w"), indent=1)
    print(f"wrote {out}")
