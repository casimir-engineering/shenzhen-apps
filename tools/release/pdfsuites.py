"""ShenzhenPDF's release suites side by side: what make would build for them, which of them must not run at the same
time, and the parts a long suite splits into. Read from make's own database (make -p) of apps/pdf/portable/Makefile
with the environment the suites run in, so a suite added to the Makefile is planned like the others without a list
here to keep up to date.

    plan = Plan(portable, suites, env)
    plan.prebuild       the files every suite's make would build before running anything: built once, by one
                        make -j, so two suites never write the same object at once
    plan.jobs           {job: (make goals, -o targets, suites it waits for, lock or None, the suite it belongs to)}

Two suites conflict, and take the same lock so they run one after the other, when their test-running targets share a
.PHONY target other than plain build steps (SHARED_BUILD_STEPS), or their recipes write the same file (-o or --work
the same path), or RUN_APART names them. A suite whose test-running targets are several (friends-tests: thirty
friends-*-check suites, the host adapter's tests and the UI end-to-end flows) runs as one job per target, then once
more with all of them given as -o, which runs only its own recipe (the stamp).
"""
import collections
import os
import re
import subprocess
import tempfile

# .PHONY targets that build and run nothing a test could disturb: two suites' makes may both run them.
SHARED_BUILD_STEPS = {"mupdf-libs"}

# Suites that pass alone but disturb each other when run at once, found by running them side by side.
# Each tuple runs one at a time.
RUN_APART = (
    # One work directory ($(BUILD)/quit-performance), one bundle identifier for their test copies.
    ("mac-quit-performance-tests", "mac-quit-integrity-tests"),
)

# Suites that time launches against fixed budgets (milliseconds measured on a quiet machine): they run last, with the
# whole pool to themselves once the machine has calmed down (app_pdf.py). The launch performance gate is not one: it
# compares this tree with the previous release in interleaved rounds, so the machine's load reaches both alike.
TIMED = {"mac-quit-performance-tests"}


def _database(portable, env):
    """make -pq's database for the Makefile, as the suites' makes see it."""
    p = subprocess.run(["make", "-pq", "-C", portable, ".szf-release-plan-nothing"], env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, errors="replace")
    return p.stdout


def _parse(text):
    """{target: {"deps": [...], "phony": bool, "recipe": str, "target": bool}} from the '# Files' section."""
    rules = {}
    in_files = False
    current = None
    not_target = False
    for line in text.split("\n"):
        if line.startswith("# Files"):
            in_files = True
            continue
        if line.startswith("# VPATH Search Paths") or line.startswith("# files hash-table stats"):
            in_files = False
        if not in_files:
            continue
        if line.startswith("# Not a target:"):
            not_target = True
            continue
        if line.startswith("\t"):
            if current:
                rules[current]["recipe"] += line[1:] + "\n"
            continue
        if line.startswith("#  Phony target"):
            if current:
                rules[current]["phony"] = True
            continue
        if not line or line.startswith("#"):
            if not line:
                current = None
            continue
        m = re.match(r"^(.+?):{1,2}(?!=)(.*)$", line)
        if not m:
            continue
        name = m.group(1).strip()
        deps = m.group(2).split("|")[0].split()
        entry = rules.setdefault(name, {"deps": [], "phony": False, "recipe": "", "target": False})
        entry["deps"] += deps
        entry["target"] = entry["target"] or not not_target
        current = name
        not_target = False
    return rules


def _expand(portable, env, tokens):
    """Second-expansion prerequisites ($(FRIENDS_SERVICE_OBJS) in the database) as make expands them."""
    tokens = sorted(t for t in tokens if "$" in t)
    if not tokens:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".mk", delete=False) as f:
        f.write("include Makefile\n")
        for i, token in enumerate(tokens):
            f.write(f"$(info SZFX{i} {token})\n")
        f.write(".PHONY: .szf-release-plan-nothing\n.szf-release-plan-nothing: ; @:\n")
        wrapper = f.name
    try:
        p = subprocess.run(["make", "-s", "-C", portable, "-f", wrapper, ".szf-release-plan-nothing"], env=env,
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace")
    finally:
        os.remove(wrapper)
    out = {}
    for line in p.stdout.splitlines():
        m = re.match(r"^SZFX(\d+) ?(.*)$", line)
        if m:
            out[tokens[int(m.group(1))]] = m.group(2).split()
    return out


class Plan:
    def __init__(self, portable, suites, env, run=None):
        """`suites`: every suite of the Makefile; `run`: those to run (default all). A suite that another one names
        as a prerequisite (mac-tab-group-integration-tests: mac-tab-group-tests) is given as -o to it, so it never
        runs twice: the other job waits for it, or it passed on this commit already."""
        self.suites = list(suites)
        run = list(run if run is not None else suites)
        rules = _parse(_database(portable, env))
        tokens = {d for r in rules.values() for d in r["deps"] if "$" in d}
        expanded = _expand(portable, env, tokens)

        def deps(name):
            out = []
            for d in rules.get(name, {}).get("deps", []):
                out += expanded.get(d, [d]) if "$" in d else [d]
            return out

        def phony(name):
            return rules.get(name, {}).get("phony", False)

        def walk(name):
            """The phony targets under `name` (itself included) and the files they need built first."""
            seen, files, stack = set(), set(), [name]
            while stack:
                node = stack.pop()
                if node in seen:
                    continue
                seen.add(node)
                for d in deps(node):
                    if phony(d):
                        stack.append(d)
                    elif rules.get(d, {}).get("target"):
                        files.add(d)
            return seen, files

        def children(node):
            return [d for d in deps(node) if phony(d) and d not in SHARED_BUILD_STEPS and d not in self.suites]

        def gathers(node):
            """A phony target that only gathers others: its recipe, if any, is silent bookkeeping (@echo, @test)."""
            recipe = rules.get(node, {}).get("recipe", "").replace("\\\n", " ")
            lines = [line.strip() for line in recipe.splitlines() if line.strip()]
            return bool(children(node)) and all(l.startswith("@") for l in lines)

        def leaves(name):
            """The test-running targets a suite is made of: friends-tests -> friends-suite -> friends-store-check,
            through targets that only gather others (whose bookkeeping runs in the suite's last job), never other
            suites. A part keeps what it needs below it (friends-vectors-check builds friends-vectors-tool)."""
            out, stack, seen = [], list(children(name)), set()
            while stack:
                node = stack.pop()
                if node in seen:
                    continue
                seen.add(node)
                if gathers(node):
                    stack += children(node)
                else:
                    out.append(node)
            return sorted(set(out))

        prebuild = set()
        units = {}  # job name -> (goals, old, after, suite)
        for suite in run:
            named = [d for d in deps(suite) if d in self.suites]
            after = [d for d in named if d in run]
            parts = leaves(suite)
            _, files = walk(suite)
            prebuild |= files
            if len(parts) >= 2:
                for part in parts:
                    units[f"{suite}/{part}"] = ([part], [], after, suite)
                units[suite] = ([suite], sorted(set(parts) | set(named)), after +
                                [f"{suite}/{p}" for p in parts], suite)
            else:
                units[suite] = ([suite], named, after, suite)
        self.prebuild = sorted(prebuild)

        # What each job's make runs and writes: the phony targets it would make and the paths its recipes write.
        touches = {}
        for job, (goals, old, _, _) in units.items():
            phonies, outputs = set(), set()
            stack, seen = list(goals), set()
            while stack:
                node = stack.pop()
                if node in seen or node in old or node in SHARED_BUILD_STEPS or \
                        (node in self.suites and node not in goals):
                    continue
                seen.add(node)
                stack += [d for d in deps(node) if phony(d)]
            for node in seen:
                phonies.add(node)
                recipe = rules.get(node, {}).get("recipe", "").replace("\\\n", " ")
                for m in re.finditer(r'(?:-o|--work)\s+(?:"([^"]+)"|([^"\s;]+))', recipe):
                    outputs.add(m.group(1) or m.group(2))
            touches[job] = (phonies, outputs)
        parent = {job: job for job in units}

        def find(x):
            while parent[x] != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        def union(a, b):
            parent[find(a)] = find(b)

        owners = collections.defaultdict(set)
        for job, (phonies, outputs) in touches.items():
            for key in phonies:
                owners[("phony", key)].add(job)
            for key in outputs:
                owners[("out", key)].add(job)
        for (kind, key), jobs in owners.items():
            jobs = sorted(jobs)
            for other in jobs[1:]:
                union(jobs[0], other)
        for group in RUN_APART:
            present = [g for g in group if g in units]
            for other in present[1:]:
                union(present[0], other)
        sizes = collections.Counter(find(j) for j in units)
        self.jobs = {}
        for job, (goals, old, after, suite) in units.items():
            root = find(job)
            lock = f"pdf-suite-group:{root}" if sizes[root] > 1 else None
            self.jobs[job] = {"goals": goals, "old": old, "after": after, "lock": lock, "suite": suite}
        self.groups = collections.defaultdict(list)
        for job in units:
            if sizes[find(job)] > 1:
                self.groups[find(job)].append(job)
