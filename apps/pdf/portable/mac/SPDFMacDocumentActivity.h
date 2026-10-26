#pragma once
#import <Foundation/Foundation.h>

// When each document the app keeps was last opened and last viewed.
//
// The owner asked the assistant to "close any document I have not viewed since a week", and it could not: the app
// kept no such dates. Two are kept now, per standardized path, in activity.yaml beside session.yaml (the app's own
// state store, SPDF_STATE_DIR):
//   opened  the document was opened, loaded into a tab or reopened;
//   viewed  its tab was the selected, visible tab of the key or main window, with the app frontmost, for at least
//           2 seconds (SPDFMacDocumentViewClock). Background tabs and restored tabs nobody looked at never count.
// Real values are Unix seconds at the top of an entry. Values backfilled once from older data (the session's tab
// activation times and focused window, Collection opens, Spotlight's last-used date) sit under "estimate" and never
// replace a real one. "notViewedSince" (estimate only) says the document was not viewed after that time.
//
// Cost: recording is a dictionary write on the main thread; nothing touches the disk, creates a queue or arms a
// timer before -start (after the first paint). Writes are coalesced on a utility queue, 10 s after the first change,
// read-merge-written under activity.lock so every window's process keeps the others' values.
NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFDocumentActivityFileName; // "activity.yaml"

@interface SPDFMacDocumentActivityStore : NSObject
+ (instancetype)sharedStore; // SPDF_STATE_DIR, else ~/Library/Application Support/ShenzhenPDF
- (instancetype)initWithDirectory:(NSString*)directory;
@property(nonatomic, readonly) NSString* directory;
// Called once on the store's queue before the first backfill: {"collection": [document rows, each with
// "editablePaths"]}. Unset: no Collection data. session.yaml and settings.yaml (recents) are read from `directory`.
@property(nonatomic, copy, nullable) NSDictionary* (^backfillSources)(void);
// Spotlight's kMDItemLastUsedDate (Unix seconds, 0 when unknown); replaceable for tests.
@property(nonatomic, copy) NSTimeInterval (^lastUsedDate)(NSString* path);
// Delay between the first unsaved change and the write (default 10 s).
@property(nonatomic) NSTimeInterval flushDelay;
// YES once anything created the queue: a test proves recording before -start stays in memory.
@property(nonatomic, readonly) BOOL hasQueue;
// Allows writes; schedules one for changes recorded during launch. Idempotent.
- (void)start;
- (void)recordOpenedPath:(NSString*)path at:(NSTimeInterval)unixTime;
- (void)recordViewedPath:(NSString*)path at:(NSTimeInterval)unixTime;
// Writes what is pending now, on the calling thread (quit).
- (void)flushNow;
// Entries by standardized path, after the one-time backfill, with unsaved changes merged in. Never on the main thread:
// the first call reads Spotlight for every known document.
- (NSDictionary<NSString*, NSDictionary*>*)entriesForPaths:(NSArray<NSString*>*)paths;
// The same, off the main thread, with the completion on the main queue.
- (void)entriesForPaths:(NSArray<NSString*>*)paths
             completion:(void (^)(NSDictionary<NSString*, NSDictionary*>* entries))completion;
// When real recording began in this profile (Unix seconds), 0 before the first write.
- (NSTimeInterval)recordedSince;
@end

// Pure helpers, headless-testable.
NSDictionary* SPDFDocumentActivityMerge(NSDictionary* _Nullable a, NSDictionary* _Nullable b);
// Several paths of one document (a Collection original, its aliases and saved copies): latest of each value.
NSDictionary* SPDFDocumentActivityCombine(NSArray<NSDictionary*>* entries);
// Backfill from older data. session: the session.yaml object; collection: document rows (path, aliases, capturedAt,
// lastOpenedAt, versions, editablePaths); recents: paths; lastUsed: Spotlight. Every value lands under "estimate".
// Only what happened before `before` counts (0: everything): from then on this build records real values, and a tab
// selected since (an activation time) was not necessarily looked at.
NSDictionary<NSString*, NSDictionary*>* SPDFDocumentActivityBackfill(NSDictionary* _Nullable session,
    NSArray* _Nullable collection, NSArray* _Nullable recents, NSTimeInterval (^_Nullable lastUsed)(NSString* path),
    NSTimeInterval before);
// What the assistant reads: last_opened, last_viewed (ISO 8601 in `zone`, or null), last_opened_estimated and
// last_viewed_estimated when the value is an estimate, not_viewed_since when only that is known.
NSDictionary* SPDFDocumentActivityFields(NSDictionary* _Nullable entry, NSTimeZone* zone);
NSString* SPDFDocumentActivityISO(NSTimeInterval unixTime, NSTimeZone* zone);
// "2026-10-19" (local midnight) or a full ISO 8601 date and time; NAN when neither.
NSTimeInterval SPDFDocumentActivityParseTime(NSString* text, NSTimeZone* zone);
// 1: not viewed since `cutoff`; 0: viewed since; -1: no record tells. Once views were recorded for the whole span
// (recordedSince at or before cutoff), only real views count; before that, estimates decide.
NSInteger SPDFDocumentActivityNotViewedSince(NSDictionary* _Nullable entry, NSTimeInterval cutoff,
                                             NSTimeInterval recordedSince);

// When a tab counts as looked at.
typedef struct {
    BOOL appActive, keyOrMain, visible, miniaturized, occluded, screensAsleep, sessionInactive, hasDocument;
} SPDFDocumentViewingState;
static inline BOOL SPDFDocumentViewingStateIsViewing(SPDFDocumentViewingState s) {
    return s.appActive && s.keyOrMain && s.visible && !s.miniaturized && !s.occluded && !s.screensAsleep &&
        !s.sessionInactive && s.hasDocument;
}

// The 2-second rule, with time passed in. A view qualifies once it lasts `threshold`; it is stamped then, every
// `heartbeat` while the person is still at the Mac (input within `idleLimit`), and when it ends unless they had left.
// Each call returns the stamps to record: [{"path", "at"}].
@interface SPDFMacDocumentViewClock : NSObject
- (instancetype)initWithThreshold:(NSTimeInterval)threshold heartbeat:(NSTimeInterval)heartbeat
                        idleLimit:(NSTimeInterval)idleLimit;
@property(nonatomic, readonly, nullable) NSString* path;
// When -tickAt:idle: should next run, 0 when nothing is pending.
@property(nonatomic, readonly) NSTimeInterval deadline;
- (NSArray<NSDictionary*>*)showPath:(nullable NSString*)path at:(NSTimeInterval)now idle:(NSTimeInterval)idle;
- (NSArray<NSDictionary*>*)tickAt:(NSTimeInterval)now idle:(NSTimeInterval)idle;
@end

NS_ASSUME_NONNULL_END
