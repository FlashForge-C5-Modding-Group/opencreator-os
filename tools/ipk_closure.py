#!/usr/bin/env python3
"""Print the ipks a set of OpenWrt packages needs beyond the image.

    ipk_closure.py MANIFEST IPKDIR ROOT...

MANIFEST is the image's manifest (lines "name - version"); IPKDIR is searched
recursively for *.ipk. Prints, sorted, the absolute paths of the ipks of the
ROOT packages and of everything they depend on, leaving out what the image
already has, libc and the kernel. Exits 1 when a dependency has no ipk.
"""
import io
import os
import sys
import tarfile

SKIP = {"libc", "kernel"}


def control_of(ipk):
    """The control file of an ipk (outer tar.gz, inner ./control.tar.gz)."""
    with tarfile.open(ipk, "r:gz") as outer:
        member = next(m for m in outer.getmembers() if m.name.lstrip("./") == "control.tar.gz")
        inner_bytes = outer.extractfile(member).read()
    with tarfile.open(fileobj=io.BytesIO(inner_bytes), mode="r:gz") as inner:
        member = next(m for m in inner.getmembers() if m.name.lstrip("./") == "control")
        return inner.extractfile(member).read().decode("utf-8", "replace")


def fields(text):
    out = {}
    key = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and key:
            out[key] += " " + line.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            key = key.strip()
            out[key] = value.strip()
    return out


def names(value):
    """Depends/Provides -> names: first alternative, no version constraint."""
    result = []
    for part in value.split(","):
        part = part.split("|", 1)[0].strip()
        part = part.split("(", 1)[0].strip()
        if part:
            result.append(part)
    return result


def load(ipkdir):
    by_name = {}
    for root, _, files in os.walk(ipkdir):
        for f in files:
            if f.endswith(".ipk"):
                path = os.path.abspath(os.path.join(root, f))
                info = fields(control_of(path))
                by_name.setdefault(info["Package"], []).append((path, info))
    packages = {}
    for name, candidates in sorted(by_name.items()):
        candidates.sort(key=lambda c: os.path.getmtime(c[0]), reverse=True)
        if len(candidates) > 1:
            print(f"ipk_closure: {name}: several ipks, using {candidates[0][0]}; ignoring "
                  + " ".join(c[0] for c in candidates[1:]), file=sys.stderr)
        packages[name] = candidates[0]
    provides = {}
    for name, (_, info) in packages.items():
        for p in names(info.get("Provides", "")):
            provides.setdefault(p, []).append(name)
    return packages, provides


def manifest_names(path):
    with open(path, encoding="utf-8") as f:
        return {line.split(" - ", 1)[0].strip() for line in f if " - " in line}


def closure(manifest, packages, provides, roots):
    image = manifest | SKIP
    needed = {}
    todo = [(root, None) for root in roots]
    while todo:
        name, parent = todo.pop()
        if name in image or name in needed:
            continue
        if name.startswith("kmod-"):
            raise SystemExit(f"ipk_closure: needs kernel module {name}"
                             + (f" (needed by {parent})" if parent else ""))
        if name not in packages:
            providers = provides.get(name, [])
            if any(p in image for p in providers):
                continue
            if len(providers) == 1:
                todo.append((providers[0], parent))
                continue
            raise SystemExit(f"ipk_closure: {name} (needed by {parent or 'the command line'}) "
                             "has no ipk under IPKDIR and is not in the image")
        path, info = packages[name]
        needed[name] = path
        todo.extend((dep, name) for dep in names(info.get("Depends", "")))
    return sorted(needed.values())


def main(argv):
    if len(argv) < 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    manifest, ipkdir, roots = argv[1], argv[2], argv[3:]
    packages, provides = load(ipkdir)
    for path in closure(manifest_names(manifest), packages, provides, roots):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
