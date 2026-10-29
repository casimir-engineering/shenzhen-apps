#!/usr/bin/env python3
"""Brings a VM's copy of a tree up to date with a tree on the Mac, sending only what changed (tauri-vm.sh with
SZF_VM_PERSIST): the guest keeps <root>/src and a manifest of it (<root>/src.manifest: sha256 and path of every file),
so a later build sends the files whose sha256 differs, removes the ones that are gone, and checks the files it sent
against their sha256 in the guest (Linux). Nothing is shared or mounted; everything goes through `prlctl exec`.

    vm-sync.py linux|windows <VM> <guest root> <tree on the Mac> [--as-root]

Files are written with the guest's time of writing (tar -m), not the Mac's: a guest whose clock runs off cannot
make cargo think a changed source older than what it built from the version before. Prints what it sent.
"""
import base64
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import time


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def local_manifest(tree, cache_path):
    """{relative path: sha256} of every file under `tree` (symbolic links as files of their target's path), with the
    digests of files whose size and time have not changed taken from the last run's cache."""
    try:
        with open(cache_path) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    out, fresh = {}, {}
    for folder, dirs, files in os.walk(tree):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(folder, name)
            rel = os.path.relpath(full, tree)
            if os.path.islink(full):
                out[rel] = "link:" + os.readlink(full)
                continue
            st = os.stat(full)
            key = f"{st.st_size}:{st.st_mtime_ns}:{st.st_mode & 0o111}"
            known = cache.get(rel)
            digest = known[1] if known and known[0] == key else sha256(full)
            fresh[rel] = [key, digest]
            out[rel] = digest
    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(fresh, f)
    os.replace(tmp, cache_path)
    return out


class Guest:
    def __init__(self, platform, vm, root, as_root):
        self.platform, self.vm, self.root = platform, vm, root
        self.exec = ["prlctl", "exec", vm] + ([] if as_root else ["--current-user"])

    def sh(self, command, data=None, check=True):
        """A command in the guest (sh -c on Linux, cmd /c on Windows); its stdout."""
        cmd = self.exec + ([command] if self.platform == "linux" else ["cmd", "/c", command])
        p = subprocess.run(cmd, input=data, capture_output=True)
        if check and p.returncode != 0:
            sys.stderr.write(p.stdout.decode(errors="replace")[-2000:] + p.stderr.decode(errors="replace")[-2000:])
            raise SystemExit(f"vm-sync: {self.vm}: failed ({p.returncode}): {command[:200]}")
        return p.stdout

    def path(self, *parts):
        sep = "/" if self.platform == "linux" else "\\"
        return sep.join([self.root, *[p.replace("/", sep) for p in parts]])

    def read_manifest(self):
        if self.platform == "linux":
            text = self.sh(f"cat {self.path('src.manifest')} 2>/dev/null || true").decode(errors="replace")
        else:
            text = self.sh(f"if exist {self.path('src.manifest')} type {self.path('src.manifest')}",
                           check=False).decode(errors="replace")
        out = {}
        for line in text.splitlines():
            digest, _, rel = line.rstrip("\r").partition("  ")
            if digest and rel:
                out[rel] = digest
        return out

    def put_file(self, data, dest):
        """Writes bytes to the guest path `dest`."""
        if self.platform == "linux":
            self.sh(f"base64 -d > {dest}", data=base64.encodebytes(data))
        elif not data:
            self.sh(f"type nul > {dest}")
        else:
            # cmd has no base64: the lines go in through findstr ('#' is not in base64) and certutil decodes them.
            b64 = dest + ".b64"
            self.sh(f"findstr /v /c:# > {b64}", data=base64.encodebytes(data))
            self.sh(f"certutil -f -decode {b64} {dest} >nul && del {b64}")

    def write_manifest(self, manifest):
        text = "".join(f"{digest}  {rel}\n" for rel, digest in sorted(manifest.items())).encode()
        self.put_file(text, self.path("src.manifest.new"))
        if self.platform == "linux":
            self.sh(f"mv -f {self.path('src.manifest.new')} {self.path('src.manifest')}")
        else:
            self.sh(f"move /y {self.path('src.manifest.new')} {self.path('src.manifest')} >nul")


def main(argv):
    if len(argv) < 4 or argv[0] not in ("linux", "windows"):
        print(__doc__, file=sys.stderr)
        return 2
    platform, vm, root, tree = argv[:4]
    guest = Guest(platform, vm, root, "--as-root" in argv[4:])
    started = time.time()
    cache = os.path.join(os.path.dirname(os.path.abspath(tree)), f".vm-sync-{platform}.json")
    want = local_manifest(tree, cache)
    if platform == "linux":
        guest.sh(f"mkdir -p {guest.path('src')}")
    else:
        guest.sh(f"if not exist {guest.path('src')} mkdir {guest.path('src')}")
    have = guest.read_manifest()
    send = sorted(rel for rel, digest in want.items() if have.get(rel) != digest)
    gone = sorted(rel for rel in have if rel not in want)
    # The manifest goes first, emptied: a sync cut short leaves the guest knowing nothing, so the next one sends all.
    if have and (send or gone):
        guest.write_manifest({})
    if gone:
        if platform == "linux":
            listing = b"".join(rel.encode() + b"\0" for rel in gone)
            guest.sh(f"cd {guest.path('src')} && xargs -0 -r rm -f --", data=listing)
        else:
            batch = "".join(f'if exist "{guest.path("src", rel)}" del /f /q "{guest.path("src", rel)}"\r\n'
                            for rel in gone).encode()
            guest.put_file(batch, guest.path("delete.cmd"))
            guest.sh(guest.path("delete.cmd"))
    sent_bytes = 0
    if send:
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz", compresslevel=3, format=tarfile.GNU_FORMAT) as tar:
            for rel in send:
                tar.add(os.path.join(tree, rel), arcname=rel, recursive=False)
        data = buffer.getvalue()
        sent_bytes = len(data)
        archive = guest.path("delta.tgz")
        guest.put_file(data, archive)
        if platform == "linux":
            guest.sh(f"tar -xzmf {archive} -C {guest.path('src')} && rm -f {archive}")
            # The files as the guest now has them, against their sha256 here.
            check = "".join(f"{want[rel]}  {rel}\n" for rel in send if not want[rel].startswith("link:")).encode()
            guest.sh(f"cd {guest.path('src')} && sha256sum --quiet -c -", data=check)
        else:
            guest.sh(f"tar -xzmf {archive} -C {guest.path('src')} && del {archive}")
    if send or gone or not have:
        guest.write_manifest(want)
    print(f"vm-sync: {vm}: {len(send)} files sent ({sent_bytes / 1e6:.1f} MB), {len(gone)} removed, "
          f"{len(want) - len(send)} unchanged, in {time.time() - started:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
