"""The machine's CPU and memory, shared by every job of a run (tools/release.sh all runs three apps' releases in one
process): a job takes what it declares before it starts and gives it back when it ends, so the apps, their platforms,
the VMs and the test suites run side by side without a hundred processes fighting for eighteen cores.

    POOL.take(cpus=4, mem=6, locks=("apple-build",))   a context manager; waits until all of it is free
    graph({name: Job(fn, deps=(...), ...)})             runs jobs as their dependencies finish, each through POOL

A job asking for more than the machine has gets the whole machine. Waiting jobs are served by priority, then in the
order they asked: a later one starts ahead of one waiting only if both fit, so a big job is never starved by small
ones. A job waiting for a lock holds nobody up.

SHENZHEN_BUILD_CPUS and SHENZHEN_BUILD_MEM_GB set the pool's size (default: one and a half times the cores, and three
quarters of the memory, since other work shares the machine).
"""
import contextlib
import itertools
import os
import subprocess
import threading
import time

from common import inherit


def _memory_gb():
    try:
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()
        return int(out) / (1 << 30)
    except (OSError, ValueError):
        return 16.0


class Pool:
    def __init__(self, cpus=None, mem=None):
        # Half again as many as the cores: most jobs wait part of the time (on a timer in a test, on a guest's disk,
        # on the network), and the scheduler is there to keep a hundred suites from starting at once, not to leave
        # cores idle.
        self.cpus = int(cpus or os.environ.get("SHENZHEN_BUILD_CPUS") or (os.cpu_count() or 8) * 3 // 2)
        self.mem = float(mem or os.environ.get("SHENZHEN_BUILD_MEM_GB") or round(_memory_gb() * 0.75))
        self.free_cpus, self.free_mem = self.cpus, self.mem
        self.held = set()
        self.cond = threading.Condition()
        self.waiting = []  # (ticket, cpus, mem, locks) in arrival order
        self.tickets = itertools.count()

    def _can_start(self, ticket, cpus, mem, locks):
        if cpus > self.free_cpus or mem > self.free_mem or self.held & set(locks):
            return False
        if not cpus and not mem:
            return True  # a lock alone takes nothing a waiting job needs (and a job may take one while it holds cores)
        for other, o_cpus, o_mem, o_locks in sorted(self.waiting):
            if other == ticket:
                break
            # A job ahead (by priority, then arrival) keeps what it waits for: a later one starts only if both fit.
            # One waiting for a lock does not hold others up.
            if not (self.held & set(o_locks)) and (cpus + o_cpus > self.free_cpus or mem + o_mem > self.free_mem):
                return False
        return True

    @contextlib.contextmanager
    def take(self, cpus=1, mem=1.0, locks=(), priority=0):
        """Lower `priority` is served first among jobs waiting at the same time (a longer job, say)."""
        cpus, mem = min(max(cpus, 0), self.cpus), min(max(mem, 0.0), self.mem)
        locks = tuple(locks)
        with self.cond:
            ticket = (priority, next(self.tickets))
            entry = (ticket, cpus, mem, locks)
            self.waiting.append(entry)
            while not self._can_start(ticket, cpus, mem, locks):
                self.cond.wait()
            self.waiting.remove(entry)
            self.free_cpus -= cpus
            self.free_mem -= mem
            self.held |= set(locks)
            self.cond.notify_all()
        try:
            yield
        finally:
            with self.cond:
                self.free_cpus += cpus
                self.free_mem += mem
                self.held -= set(locks)
                self.cond.notify_all()


POOL = Pool()


class Job:
    """fn() run once every job in `deps` has finished (whether or not it passed: fn decides from `results`), holding
    `cpus`, `mem` and `locks` of POOL. A job whose fn raises has failed; graph() raises the first failure, by name
    order, once every job has finished or can no longer start."""

    def __init__(self, fn, deps=(), cpus=1, mem=1.0, locks=(), priority=0):
        self.fn, self.deps, self.cpus, self.mem, self.locks = fn, tuple(deps), cpus, mem, tuple(locks)
        self.priority = priority


def graph(jobs, pool=None):
    """Runs {name: Job}; returns {name: (ok, result or exception, seconds)}."""
    pool = pool or POOL
    done = {name: threading.Event() for name in jobs}
    results = {}
    lock = threading.Lock()
    for name, job in jobs.items():
        for dep in job.deps:
            if dep not in jobs:
                raise ValueError(f"{name} depends on {dep}, which is not a job")

    def one(name):
        job = jobs[name]
        for dep in job.deps:
            done[dep].wait()
        start = time.time()
        try:
            with pool.take(job.cpus, job.mem, job.locks, job.priority):
                start = time.time()
                value = job.fn()
            outcome = (True, value, time.time() - start)
        except KeyboardInterrupt as error:
            outcome = (False, error, time.time() - start)
        except BaseException as error:  # noqa: BLE001 -- returned to the caller
            outcome = (False, error, time.time() - start)
        with lock:
            results[name] = outcome
        done[name].set()

    order = sorted(jobs, key=lambda name: jobs[name].priority)  # the first to ask are served first among equals
    threads = [threading.Thread(target=inherit(one), args=(name,), name=f"job:{name}", daemon=True) for name in order]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    interrupted = [n for n, (ok, value, _) in results.items() if not ok and isinstance(value, KeyboardInterrupt)]
    if interrupted:
        raise KeyboardInterrupt
    return results


def raise_first(results):
    for name in sorted(results):
        ok, value, _ = results[name]
        if not ok:
            raise value
