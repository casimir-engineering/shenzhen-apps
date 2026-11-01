"""Shenzhen 3D's hand-over release: the release a 3D release also publishes, under the same tag, on the repository of
the owner named by SHENZHEN_3D_MIRROR_OWNER, from which earlier builds update. It carries the public build's Mac update
files, byte for byte, so a Mac build of that owner installs the public build through its own updater; from then on the
app reads only the public releases (apps/3d/docs/UPDATES.md, Moving a private channel to the public one). Builds of
that owner on Windows, Linux and Android have no updater, so the notes tell their users where to download."""
import os
import re

PUBLIC_OWNER = "casimir-engineering"
REPOSITORY = "shenzhen-3D"
# The Mac update files the earlier builds' updater reads: latest-mac.yml and the ZIP it names, with the DMG and the
# blockmaps beside them as in every release. Not build-info.json, SHA256SUMS.txt or the other platforms' packages.
MAC_UPDATE_FILE = re.compile(r"^(latest-mac\.yml|Shenzhen-3D-[0-9.]+-Apple-Silicon\.(zip|dmg)(\.blockmap)?)$")


def public_release_url(tag):
    return f"https://github.com/{PUBLIC_OWNER}/{REPOSITORY}/releases/tag/{tag}"


def files(paths):
    """The hand-over's assets among a release's files: the Mac update files, which must all be there."""
    chosen = [p for p in paths if MAC_UPDATE_FILE.match(os.path.basename(p))]
    names = {os.path.basename(p) for p in chosen}
    if "latest-mac.yml" not in names or not any(n.endswith(".zip") for n in names):
        raise ValueError(f"no latest-mac.yml and Mac ZIP among {sorted(os.path.basename(p) for p in paths)}")
    return chosen


def notes(version, tag):
    """The hand-over's release notes, for someone who runs an earlier build of this repository and opens its
    releases: where Shenzhen 3D is now, and what updating does on their system."""
    url = public_release_url(tag)
    return f"""# Shenzhen 3D is now open source

Shenzhen 3D is now released at [{PUBLIC_OWNER}/{REPOSITORY}](https://github.com/{PUBLIC_OWNER}/{REPOSITORY}/releases), \
and new versions come out there. This release is [Shenzhen 3D {version}]({url}) from there, which says what's new.

**Mac.** Open **Updates** in the footer of the Shenzhen 3D window: it offers version {version}. Download it, then \
restart to install it. From then on, Shenzhen 3D checks for updates there. It no longer needs GitHub access and \
removes the access you connected. If Updates asks you to connect GitHub first, you can instead download the Mac \
version from [Shenzhen 3D {version}]({url}) and install it as usual.

**Windows, Linux and Android.** The version you have doesn't check for updates. Download the file for your system \
from [Shenzhen 3D {version}]({url}) and install it as you installed this one. Your files and settings stay. From then \
on, Shenzhen 3D tells you when there is a new version.
"""


def mac_dmg(release):
    version = release.get("tag_name", "").split("-", 1)[-1].lstrip("v")
    name = f"Shenzhen-3D-{version}-Apple-Silicon.dmg"
    return next((a for a in release.get("assets", []) if a.get("name") == name), None)


def last_own_build(mirror_releases, public_releases, tag):
    """The newest published release on the mirror, other than `tag`, whose Mac app is a build of the mirror's own:
    the one people there may still run, whose updater the hand-over must move. A hand-over release carries the public
    build, so its DMG has the digest of the public release of the same tag; those are passed over."""
    public = {}
    for release in public_releases:
        if not release.get("draft"):
            dmg = mac_dmg(release)
            if dmg and dmg.get("digest"):
                public[release["tag_name"]] = dmg["digest"]
    for release in mirror_releases:
        if release.get("draft") or release.get("tag_name") == tag:
            continue
        dmg = mac_dmg(release)
        if not dmg:
            continue
        if dmg.get("digest") and public.get(release["tag_name"]) == dmg["digest"]:
            continue
        return release
    return None
