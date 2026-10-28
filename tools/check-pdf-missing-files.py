#!/usr/bin/env python3
"""check-pdf-missing-files.py: every file ShenzhenPDF's builds name is committed.

    tools/check-pdf-missing-files.py [--rev REV]

Reads the commit (HEAD by default) straight from git, so a file that exists only on someone's disk counts as missing,
and takes under a second, so it fails before anything is built. Under apps/pdf/portable:

  - every quoted #include / #import in a committed C, C++ or Objective-C file names a committed file: next to the file
    that includes it, or anywhere in the repository under that relative path (the -I folders the makefiles pass);
  - every source or header path the Makefile and its *.mk files spell out (mac/Foo.mm, core/bar.h) is committed.

Exit 0 when nothing is missing, 1 with each missing file and where it is named otherwise. tools/release/app_pdf.py runs
it in preflight and .github/workflows/pdf.yml before the build; tools/release/test_release.py tests it.
"""
import argparse
import re
import subprocess
import sys

PORTABLE = "apps/pdf/portable/"
SOURCE = re.compile(r"\.(c|cc|cpp|h|hh|hpp|m|mm)$")
INCLUDE = re.compile(r'^\s*#\s*(?:include|import)\s+"([^"]+)"')
INCLUDE_ERE = r'^[[:space:]]*#[[:space:]]*(include|import)[[:space:]]+"'
MAKE_PATH = re.compile(r"(?<![\w$(./-])((?:mac|core|friends|linux|release|gfx)/[\w+./-]+\.(?:c|cc|cpp|h|hh|hpp|m|mm))\b")


def git(root, *args):
    result = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    if result.returncode not in (0, 1):  # git grep answers 1 when nothing matches
        raise SystemExit(result.stderr.strip())
    return result.stdout


def normalize(path):
    out = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == ".." and out and out[-1] != "..":
            out.pop()
        else:
            out.append(part)
    return "/".join(out)


def missing(root, rev):
    files = set(git(root, "ls-tree", "-r", "--name-only", rev).splitlines())
    suffixes = {"/".join(path.split("/")[i:]) for path in files for i in range(path.count("/") + 1)}

    def committed(folder, name):
        relative = normalize(name)
        while relative.startswith("../"):
            relative = relative[3:]
        return normalize(f"{folder}/{name}") in files or relative in suffixes

    problems = []
    for hit in git(root, "grep", "-I", "-n", "-E", INCLUDE_ERE, rev, "--", PORTABLE).splitlines():
        path, number, text = hit[len(rev) + 1:].split(":", 2)
        match = INCLUDE.match(text)
        if SOURCE.search(path) and match and not committed(path.rsplit("/", 1)[0], match.group(1)):
            problems.append(f"{path}:{number}: includes \"{match.group(1)}\", which is not committed")
    makefiles = sorted(p for p in files if p == PORTABLE + "Makefile" or (p.startswith(PORTABLE) and p.endswith(".mk")))
    for path in makefiles:
        for number, line in enumerate(git(root, "show", f"{rev}:{path}").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for name in MAKE_PATH.findall(line):
                if PORTABLE + name not in files:
                    problems.append(f"{path}:{number}: names {name}, which is not committed")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rev", default="HEAD")
    rev = parser.parse_args().rev
    root = git(".", "rev-parse", "--show-toplevel").strip()
    problems = missing(root, rev)
    if problems:
        print(f"Files ShenzhenPDF's builds need are not committed in {rev}:", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        print("Commit them, or remove what names them.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
