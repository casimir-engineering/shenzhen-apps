#import <Foundation/Foundation.h>

@class NSAlert;

NS_ASSUME_NONNULL_BEGIN

/// Runtime-gated GitHub-release self-updater for the non-sandboxed Developer ID
/// build. Every entry point early-returns when spdf_is_sandboxed() is YES so a
/// third-party sandboxed repackaging cannot attempt to replace its own bundle.
@interface SPDFUpdater : NSObject

+ (instancetype)shared;

/// Launch hook. Runs strictly after first paint, in the primary process only.
/// Sandbox gate -> autoUpdate gate -> flock'd 24h gate -> Background-QoS check.
- (void)scheduleDailyUpdateCheckIfNeeded;

/// Keeps the silent daily check alive in a continuously-running app. Armed
/// post-first-paint in EVERY window process (primary, restored sibling,
/// detached tab) so the schedule survives the primary window closing; the
/// flock'd 24h gate still collapses all processes' triggers to at most one
/// check per day globally. Idempotent. An hourly Background-QoS dispatch timer
/// with generous leeway, plus the two wall-clock catch-ups timers miss across
/// sleep (NSCalendarDayChangedNotification, NSWorkspaceDidWakeNotification),
/// each re-run the exact launch gate chain: sandbox -> autoUpdate -> flock'd
/// 24h gate -> Background-QoS check. The timer stays armed while autoUpdate is
/// off — every fire early-returns on the live setting — so re-enabling the
/// setting resumes daily checks without a relaunch.
- (void)armRecurringUpdateCheck;

/// Launch-time post-update health handshake (§5.9.6 / §5.10). Runs in the
/// primary process only, before scheduleDailyUpdateCheckIfNeeded. Under
/// update.lock: if pendingTag matches the now-running version, writes update_ok,
/// deletes <bundle>.app.old, clears the lease, and shows the one-time success
/// banner; if pendingTag is set but the running version does NOT match it (the
/// new version failed to come up), rolls <bundle>.app.old back into place and
/// reveals it in the preferred file manager. Always sweeps an aged orphaned .old / staging dirs.
- (void)consumePendingUpdateMarkerAndSweep;

/// The "Check for Updates…" menu path passes userInitiated=YES (bypasses the
/// 24h gate, ignores Skip/Later, surfaces both up-to-date and failure states).
/// The silent daily path passes NO.
- (void)checkForUpdatesUserInitiated:(BOOL)userInitiated;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// YES when a third-party repackaging unexpectedly runs inside an application
/// sandbox, NO for the supported Developer ID build. Inspects the dynamic code-signing entitlements dict for
/// com.apple.security.app-sandbox, corroborated by APP_SANDBOX_CONTAINER_ID.
BOOL spdf_is_sandboxed(void);

/// Numeric per-field comparison of "YY.M.DD-BUILD" version strings split on
/// "[. -]". YY.M.DD is the primary key; -BUILD is a same-day tiebreaker.
/// Malformed input compares as ordered-same. Never lexical.
NSComparisonResult spdf_compare_versions(NSString* _Nullable a, NSString* _Nullable b);

/// Requires an exact numeric YY.M.DD-BUILD match between a release tag and an
/// extracted app's two plist version fields. Missing/malformed build fields
/// fail closed so a same-day wrong-build asset cannot be installed repeatedly.
BOOL spdf_release_tag_matches_bundle_version(NSString* _Nullable tag,
                                             NSString* _Nullable shortVersion,
                                             NSString* _Nullable build);

/// Requires an exact four-component YY.M.DD-BUILD match for the launch-time
/// health handshake. This deliberately rejects a same-day build mismatch.
BOOL spdf_release_tag_matches_running_version(NSString* _Nullable tag,
                                              NSString* _Nullable runningVersion);

/// Pure fire/delay decision for the silent daily check (consumed under
/// update.lock by the gate; every trigger source funnels through it). Returns
/// 0 when a check is due now, the positive number of seconds until the rolling
/// 24h gate next opens, or -1 when no check may run at all (autoUpdate off).
/// haveLastCheck is NO on a fresh install (update.json has no lastUpdateCheck
/// stamp) => due immediately. A wall clock set backwards yields a delay > 24h
/// (the gate stays closed until real time catches up).
NSTimeInterval spdf_daily_check_delay(BOOL autoUpdateEnabled, BOOL haveLastCheck,
                                      NSTimeInterval lastCheckEpoch, NSTimeInterval nowEpoch);

/// Formats a GitHub release body for the update alert: keeps only the
/// highlights section above the first horizontal rule, renders Markdown list
/// items as "• " lines with real line breaks, rejoins hard-wrapped
/// continuation lines, strips inline Markdown markers and control/bidi
/// characters (anti-spoofing), drops blank lines, and caps the result at 500
/// characters on a line boundary.
NSString* spdf_format_release_notes_for_alert(NSString* _Nullable body);

/// Attributed variant of the alert notes: identical sanitation, but Markdown
/// **emphasis** spans survive as bold runs at the given font size.
NSAttributedString* spdf_attributed_release_notes_for_alert(NSString* _Nullable body, CGFloat fontSize);

/// Constructs the exact alert used by the updater and the local release-notes
/// preview harness. The release notes render in an attributed accessory label
/// below the informative text. The caller presents the alert and handles its
/// response.
NSAlert* spdf_make_update_available_alert(NSString* tag, NSString* runningVersion,
                                          NSString* _Nullable releaseBody);

/// Offline Security.framework verification of a signed DMG (isApp == NO) or an
/// extracted .app (isApp == YES). Requires the full Developer ID requirement
/// (Apple anchor + WWDR marker + Developer ID Application leaf marker) plus a
/// pinned Team ID 66LJ4BV7Q3. For an app it additionally asserts the
/// hardened-runtime flag and bundle id com.intuition.shenzhenpdf. For the DMG it
/// additionally requires a valid stapled notarization ticket. Returns NO and
/// fills *error on any failure. This is the sole anti-tamper trust boundary.
BOOL spdf_verify_signed_bundle(NSURL* url, BOOL isApp, NSError* _Nullable* _Nullable error);

/// Foundation-only swap/relaunch helper invoked from main()'s --post-update
/// short-circuit, running from the CURRENT trusted in-place binary. Polls until
/// siblings exit, swaps via move-aside two-rename, re-registers Launch Services,
/// relaunches, and rolls back on failure. Returns 0 on success.
int spdf_run_post_update_helper(NSString* stagedAppPath, NSString* targetBundlePath);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
