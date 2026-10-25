"""The version each built artifact shows people, read from the artifact itself, for the verify stage: a release stops
when any build it made would show another version than the one being released.

Where each app shows its version, and where that comes from:

  Shenzhen 3D   the footer (v0.2.2 · Updates) and the Updates dialog. The page's own version is the
                <meta name="shenzhen-3d-version"> vite.config.ts writes into index.html from package.json; the footer
                and the dialog show the running app's version once it answers, which is package.json's too: the
                Electron app's app.asar package.json and Info.plist (Mac), tauri.conf.json's `version`, which names
                package.json (Android versionName, iOS CFBundleShortVersionString, the Windows exe's ProductVersion,
                the Linux packages' version).
  ShenzhenPDF   About and the update dialog: Info.plist's SZFReleaseTag (26.10.20-1).
  Shenzhen Files  About and the update dialog: Info.plist's SZFReleaseTag.
"""
import glob
import io
import json
import os
import plistlib
import re
import struct
import subprocess
import tarfile
import zipfile

from common import Failure

META = re.compile(rb'<meta name="shenzhen-3d-version" content="([^"]*)"')


def require(what, expected, shown):
    """`shown` is [(where, version)]; a Failure names every place that shows another version than `expected`."""
    wrong = [f"{where} shows {value!r}" for where, value in shown if value != expected]
    if not shown:
        raise Failure(f"{what}: found no version to check")
    if wrong:
        raise Failure(f"{what} would not show {expected}: " + "; ".join(wrong))


# ---- readers --------------------------------------------------------------------------------------------------

def plist_value(data, key):
    return plistlib.loads(data).get(key)


def page_version(html):
    m = META.search(html)
    return m.group(1).decode() if m else None


def asar_file(archive, inner):
    """One file out of an Electron app.asar (unpacked files are not in it)."""
    with open(archive, "rb") as f:
        head = f.read(16)
        header_size, json_size = struct.unpack("<I", head[4:8])[0], struct.unpack("<I", head[12:16])[0]
        node = json.loads(f.read(json_size))
        for part in inner.split("/"):
            node = node["files"][part]
        f.seek(8 + header_size + int(node["offset"]))
        return f.read(node["size"])


def pe_product_version(data):
    """A Windows executable's VERSIONINFO ProductVersion (the last one: the resource section comes last)."""
    key = "ProductVersion".encode("utf-16-le") + b"\0\0"
    i = data.rfind(key)
    if i < 6:
        return None
    start = i - 6
    _, chars, _ = struct.unpack("<HHH", data[start:i])
    j = i + len(key)
    j += (4 - (j - start) % 4) % 4
    return data[j:j + 2 * chars].decode("utf-16-le", "replace").rstrip("\0")


def deb_version(path):
    """The Version field of a .deb's control file."""
    data = open(path, "rb").read()
    if not data.startswith(b"!<arch>\n"):
        raise Failure(f"{path} is not a Debian package")
    at = 8
    while at + 60 <= len(data):
        name, size = data[at:at + 16].decode().strip().rstrip("/"), int(data[at + 48:at + 58].decode().strip())
        body = data[at + 60:at + 60 + size]
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(body)) as tar:
                member = next(m for m in tar.getmembers() if os.path.basename(m.name) == "control")
                text = tar.extractfile(member).read().decode()
            m = re.search(r"^Version:\s*(\S+)", text, re.M)
            return m.group(1) if m else None
        at += 60 + size + (size % 2)
    return None


def rpm_version(path):
    """An .rpm's VERSION tag (1001), from its main header."""
    data = open(path, "rb").read()
    if data[:4] != b"\xed\xab\xee\xdb":
        raise Failure(f"{path} is not an RPM package")

    def header(at):
        if data[at:at + 3] != b"\x8e\xad\xe8":
            raise Failure(f"{path}: no RPM header at {at}")
        count, size = struct.unpack(">II", data[at + 8:at + 16])
        index, store = at + 16, at + 16 + 16 * count
        return count, size, index, store

    count, size, _, store = header(96)
    at = store + size
    at += (8 - at % 8) % 8  # the signature header is padded to 8 bytes
    count, size, index, store = header(at)
    for n in range(count):
        tag, kind, offset, _ = struct.unpack(">IIII", data[index + 16 * n:index + 16 * n + 16])
        if tag == 1001 and kind == 6:
            return data[store + offset:data.index(b"\0", store + offset)].decode()
    return None


# ---- per artifact ---------------------------------------------------------------------------------------------

def mac_electron_app(app):
    """Shenzhen 3D on the Mac: Info.plist, app.getVersion() (app.asar's package.json) and the page."""
    asar = os.path.join(app, "Contents/Resources/app.asar")
    return [("Info.plist CFBundleShortVersionString",
             plist_value(open(os.path.join(app, "Contents/Info.plist"), "rb").read(), "CFBundleShortVersionString")),
            ("app.asar package.json", json.loads(asar_file(asar, "package.json")).get("version")),
            ("app.asar dist/index.html", page_version(asar_file(asar, "dist/index.html")))]


def mac_release_app(app):
    """ShenzhenPDF and Shenzhen Files: what About and the update dialog show (SZFReleaseTag)."""
    return [("Info.plist SZFReleaseTag",
             plist_value(open(os.path.join(app, "Contents/Info.plist"), "rb").read(), "SZFReleaseTag"))]


def web_zip(path):
    with zipfile.ZipFile(path) as z:
        return [("index.html", page_version(z.read("index.html")))]


def ios_ipa(path):
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        return [(f"{n} CFBundleShortVersionString", plist_value(z.read(n), "CFBundleShortVersionString"))
                for n in names]


def ios_simulator_tar(path):
    with tarfile.open(path) as tar:
        found = [m for m in tar.getmembers() if re.fullmatch(r"(\./)?[^/]+\.app/Info\.plist", m.name)]
        return [(f"{m.name} CFBundleShortVersionString",
                 plist_value(tar.extractfile(m).read(), "CFBundleShortVersionString")) for m in found]


def windows_installer(path):
    """The Setup.exe's own ProductVersion (Tauri writes the app's version into it)."""
    return [("ProductVersion", pe_product_version(open(path, "rb").read()))]


def windows_msi(path, work):
    """The app's exe inside the .msi (the largest executable in it, extracted with 7-Zip): its ProductVersion."""
    tool = next((t for t in ("7zz", "7z") if subprocess.run(["which", t], capture_output=True).returncode == 0), None)
    if not tool:
        raise Failure("checking the Windows .msi needs 7-Zip (brew install sevenzip)")
    os.makedirs(work, exist_ok=True)
    subprocess.run([tool, "x", "-y", f"-o{work}", path], check=True, capture_output=True)
    exes = [p for p in glob.glob(os.path.join(work, "**", "*"), recursive=True)
            if os.path.isfile(p) and open(p, "rb").read(2) == b"MZ"]
    if not exes:
        raise Failure(f"{path} holds no executable")
    exe = max(exes, key=os.path.getsize)
    return [(f"the app's exe ProductVersion", pe_product_version(open(exe, "rb").read()))]


def android_badging(badging):
    """aapt2 dump badging's versionName (the Updates dialog shows it; the footer shows the same once it answers)."""
    m = re.search(r"versionName='([^']*)'", badging)
    return [("versionName", m.group(1) if m else None)]
