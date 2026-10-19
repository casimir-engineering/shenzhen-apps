# Group and workspace performance — 24 September 2026

This pass measured the model work behind tab-strip refresh and the new vertical sidebar before changing it. No running reader was launched, stopped, or captured. The benchmarks operate on synthetic tabs; workspace tests use an activation-prohibited headless AppKit process.

## Measurements and decisions

Machine: Apple M5 Max, arm64. Baseline: `56b85448e`. Times are mean microseconds per call, measured with `CFAbsoluteTimeGetCurrent`, excluding fixture construction. Model benchmark uses `-O2`, 1,000 iterations per case; workspace benchmark uses the existing test target's compiler flags and 250 iterations. Other agents were testing concurrently, so small differences are noise rather than claimed improvements.

| Tab-strip normalization fixture | Before | After | Work removed |
|---|---:|---:|---|
| 20 tabs, two groups | 0.84 µs | 0.70 µs | Repeated preceding-tab scan |
| 200 tabs, 20 groups | 52.82 µs | 6.91 µs | ~7.6× faster |
| 200 tabs, 200 groups | 452.00 µs | 29.58 µs | ~15× faster |
| 1,000 tabs, 100 groups | 1,131.25 µs | 24.33 µs | ~46× faster |
| 1,000 tabs, 1,000 groups | 11,340.75 µs | 107.29 µs | ~106× faster |
| 1,000 ordinary ungrouped tabs | 14.53 µs | 15.60 µs | Unchanged algorithm; timing noise |

`updateTabStrip` calls normalization whenever it refreshes. The prior canonicality check scanned all preceding tabs at each new group boundary. A lazily allocated set now detects repeated group identifiers in one pass. Ordinary tabs return before this check, and one contiguous group needs no set. The actual normalization/reordering/General preservation logic and YAML format remain unchanged.

The deterministic regression counts group-property reads rather than enforcing machine-dependent timing thresholds. At 1,000 singleton groups, reads fall from **500,504 to 1,004**. The new `--verify` regression fails on the old implementation (exit 1) and passes on the new one.

| Workspace path, 1,000 tabs / 100 groups | Before | After |
|---|---:|---:|
| Build group snapshots | 283.19 µs | 285.98 µs |
| Unchanged visible refresh | 387.20 µs | 388.56 µs |
| Unchanged visible show | 391.67 µs | 395.81 µs |
| Refresh while entire sidebar hidden | 389.20 µs | 0.004 µs |

The final number is at the timer floor: it means a guard and return, not a precise four-nanosecond guarantee. The manager's own `hidden` flag describes its selected mode, so it could remain false while its sidebar ancestor was hidden. Refresh now checks the sidebar visibility preference before constructing snapshots. A saved hidden Groups/Search workspace also defers panel construction and Collection-panel work until reveal. Showing the sidebar rebuilds from current tabs, preserving edits made while hidden.

Visible refresh already skips unchanged table reloads. Its measured sub-millisecond cost at 1,000 tabs did not justify a new invalidation/cache mechanism in this pass.

## Reproduce

From the repository root:

```sh
clang++ -O2 -std=c++17 -fobjc-arc -Wall -Wextra -Werror \
  -Iportable/mac -Iportable/core -Imupdf/include \
  portable/mac/tests/SPDFMacTabGroupPerformance.mm \
  portable/mac/SPDFMacTabGroups.mm -framework Cocoa -o /tmp/spdf-group-perf
/tmp/spdf-group-perf --verify
make -C portable mac-sidebar-workspace-tests
portable/build/SPDFMacSidebarWorkspaceTests --benchmark
```

To measure the model baseline with the same harness, obtain `portable/mac/SPDFMacTabGroups.mm` from commit `56b85448e` in a temporary file and substitute that file in the compiler command. Run without `--verify` for full baseline timings; with `--verify`, the deterministic complexity check intentionally fails.

Validation: `mac-tab-group-tests`, `mac-tab-group-interaction-tests`, `mac-agent-group-tests`, and `mac-sidebar-workspace-tests` passed. Workspace tests cover hidden-refresh laziness, first reveal, default startup without manager work, General rename/new routing, hidden membership and YAML restoration. Existing group tests cover canonical identity, contiguous ordering, drag/drop layout, selection and codec roundtrips. The hidden-refresh regression was observed failing against the old code before the guard was added.

These are bounded microbenchmarks, not whole-app launch or rendering measurements. No visible design, document rendering, storage policy, or persisted schema changed.
