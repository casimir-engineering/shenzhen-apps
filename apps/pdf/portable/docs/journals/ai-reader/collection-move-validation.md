# Collection move and adjustable capacity

10 October 2026

Dynamic capacity now accepts an integer percentage from 50 to 80, defaulting to 80. The selected percentage persists across restarts and switching between dynamic, static and unlimited storage. Preview/apply merges omitted policy fields with saved settings, and the budget uses overflow-safe integer arithmetic on free volume bytes plus retained Collection bytes. Invalid/out-of-range values normalize to a supported value.

The previous relocation code verified copied content but removed only objects and the old manifest. Indexes, thumbnails and other cached payload therefore remained duplicated at the previous location. The replacement move builds a private staging directory, copies without loading whole documents into memory, verifies hashes using 64 KiB buffers, and synchronizes files and folders before switching the redirect. A failure before the switch normally rolls back the staging destination and leaves the original active. If an editable-tree rollback itself fails, the destination is retained and the error identifies the recovery state; it is never deleted as disposable staging.

After the durable switch, every old payload file is removed, including indexes and thumbnails. Preview and editable paths are replaced atomically with symlinks, preserving restored tabs and other running windows. Only `redirect.json`, the zero-length lock file, and those two compatibility symlinks remain at the old location. These are routing metadata, not duplicate document storage. If cleanup fails after switching, the error explicitly says that the new location is active and safe; selecting that location again retries old-payload cleanup.

Regression coverage includes failed-copy rollback; old payload absence; new thumbnail/index contents; saved preview/editable paths; independent store instances following the redirect; cleanup retry; selected percentages at 50, 65 and 80; persistence across mode changes and store instances; and saturated integer-capacity arithmetic. `make -C portable mac-collection-store-tests` exercises Store, Integrity and Cleanup suites. The verification log is recorded by the implementation run.

## Concurrent edits and recovery boundaries

Immutable snapshots are copied and streamed-hash verified. Editable copies require stronger handling: after the initial copy, a same-volume atomic directory exchange transfers the original editable file inodes to the new location. The old path becomes a compatibility symlink in the same exchange. This preserves both a save made after copying and writes through a file descriptor opened before the move. A failed redirect publication exchanges the original live directory back before discarding staging.

Moving a Collection with editable copies between disks is refused with an actionable message to choose a folder on the same disk. Copying and comparing a mutable file cannot guarantee safety for an uncoordinated writer with an already-open file descriptor. Immutable-only Collections can still move between disks. No complete process-crash rollback is claimed: interruption after the editable exchange but before publishing the redirect leaves original paths readable through the symlink and retains the destination. A subsequent relocation detects this state and requests recovery instead of deleting the destination holding the mutable bytes.

Cleanup refuses any real nonempty legacy editable directory left by an earlier move, rather than assuming the active copy contains its newest edits. Directory inspection failures also stop cleanup. The error identifies the retained path for reconciliation; compatibility links created by normal moves do not trigger this protection.

Additional regressions exercise immutable-only cross-volume policy, refusal when editable copies exist, deterministic late-save preservation, writes through an already-open descriptor, rollback after editable inode transfer, and cleanup retry with divergent legacy editable bytes. Final full Store/Integrity/Cleanup validation: `/tmp/collection-move-lossless-final-verified.log` (exit 0). No app launch or user document changes were needed.
