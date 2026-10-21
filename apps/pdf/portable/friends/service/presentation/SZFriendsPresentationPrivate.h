// Shenzhen Friends presentation internals, shared by the catalog, the strings and the snapshot builder's files.
// Not a public header: the helper uses SZFriendsPresentation.h only.

#import "service/presentation/SZFriendsPresentation.h"

NS_ASSUME_NONNULL_BEGIN

// JSON booleans. @(a > b) boxes an int, which NSJSONSerialization writes as 1 rather than true, and PROTOCOL.md
// types these fields bool; every boolean a snapshot carries goes through here.
static inline NSNumber *SZFriendsBool(BOOL value) {
    return value ? @YES : @NO;
}

// The store's failure keys (SZFriendsOutbox.h, SZFriendsTransfers.h), which a Failed item carries in
// SZFriendsItemFacts.failureReason. The store persists them, so they never change; they are spelled out
// here so the presentation links without the store. The presentation tests read the store's headers and fail when
// a key declared there is missing from this list or has no words in the catalog.
static NSString *const SZFriendsFailureNotDelivered30Days = @"not_delivered_30_days";
static NSString *const SZFriendsFailureRefused = @"refused";
static NSString *const SZFriendsFailureSourceMissing = @"source_missing";
static NSString *const SZFriendsFailureDigestMismatch = @"digest_mismatch";

// Catalog keys a lookup asked for and did not find. Tests build every snapshot and then require this to be empty,
// so a typo in a key fails a test instead of showing the key to someone.
NSSet<NSString *> *SZFriendsMissingCatalogKeys(void);

// The English catalog: key -> template with {name} placeholders. Plural entries are "<key>.one" and
// "<key>.other"; a language without plural forms (Chinese) supplies ".other" only.
NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalog(void);
NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogViews(void); // part two, merged into the above
NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogMentions(void); // mentions, merged into the above
NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogLinks(void);    // links, merged into the above
NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogJoin(void);     // joining, merged into the above
NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogDevices(void);  // several computers, merged into the above

@interface SZFriendsStrings (SZFriendsInternal)
@property(nonatomic, readonly) SZFriendsAudience *audience;
// The helper announces "online" to this audience: friends are reached online too, so waiting words say "online or
// nearby", never "nearby" alone (SZFriendsAudience.helperCapabilities).
@property(nonatomic, readonly) BOOL reachesOnline;

- (NSString *)text:(NSString *)key;
- (NSString *)text:(NSString *)key values:(nullable NSDictionary<NSString *, NSString *> *)values;
// Picks "<key>.one" or "<key>.other" for `count` and fills {count} along with `values`.
- (NSString *)text:(NSString *)key
             count:(NSInteger)count
            values:(nullable NSDictionary<NSString *, NSString *> *)values;

// Clock and calendar wording, all in the audience's time zone.
- (NSString *)clockLabelForDate:(NSDate *)date;                       // "14:32"
- (NSString *)dayLabelForDate:(NSDate *)date now:(NSDate *)now;       // "Today", "Thursday", "2 Oct"
- (NSString *)dayAccessibilityLabelForDate:(NSDate *)date now:(NSDate *)now; // "Today", "2 October"
- (NSString *)timeAccessibilityLabelForDate:(NSDate *)date now:(NSDate *)now; // "14:40", "yesterday", "3 October"
- (NSString *)momentPhraseForDate:(NSDate *)date now:(NSDate *)now;           // "today at 14:40", "3 Oct at 09:10"
- (NSString *)momentAccessibilityPhraseForDate:(NSDate *)date now:(NSDate *)now; // "2 October at 16:20"
- (NSString *)dayPhraseForDate:(NSDate *)date now:(NSDate *)now;             // "today", "on 3 Oct"
- (NSString *)dayItemIDForDate:(NSDate *)date;                                // "d_20261012"
- (BOOL)date:(NSDate *)date isSameDayAs:(NSDate *)other;

- (NSString *)durationLabelForSeconds:(double)seconds;              // "about 20 s", "about 6 min"
- (NSString *)durationAccessibilityLabelForSeconds:(double)seconds; // "about 20 seconds"
// The rate an estimate on `route` uses: the measured one, except on the relay, where it never exceeds the relay's cap
// and is assumed from the relay's measured throughput until one is measured (0 elsewhere: no estimate yet).
- (double)estimateBytesPerSecond:(double)measured route:(SZFriendsRouteMethod)route;
- (nullable NSString *)transferEstimateAccessibilityForRemainingBytes:(uint64_t)bytes
                                                       bytesPerSecond:(double)bytesPerSecond
                                                                route:(SZFriendsRouteMethod)route;

// A catalog phrase used inside a longer spoken sentence: first letter lowercased ("Nearby, ..." -> "nearby, ...").
// Never applied to what people wrote (names, messages, file names).
- (NSString *)spokenFragment:(NSString *)phrase;
// What a sentence calls someone: the first word of their name, or the whole Friends ID in its display form ("Mei",
// "tulip-canyon" with U+2011 for the hyphen).
- (NSString *)firstNameForName:(nullable NSString *)name friendsID:(nullable NSString *)friendsID;
// A Friends ID as text shows it: its words joined by U+2011, a hyphen that never breaks a line, so "walnut-" and
// "valley" never land on two lines and read as two things. Raw IDs (friends_id fields, intents) keep the ASCII
// hyphen, and every place that reads an ID typed or pasted back accepts U+2011 as "-" (PROTOCOL.md § Shared objects).
- (NSString *)displayID:(nullable NSString *)friendsID;
- (NSString *)joinedList:(NSArray<NSString *> *)items; // "A", "A and B", "A, B and C"
- (NSString *)kindLabelForFileName:(NSString *)fileName extension:(nullable NSString *)extension; // "PDF"
- (NSString *)groupedComparisonCode:(NSString *)digits;     // "418 270"
- (NSString *)spokenComparisonCode:(NSString *)digits;      // "4 1 8, 2 7 0"
@end

@interface SZFriendsSnapshotBuilder (SZFriendsShared)
@property(nonatomic, readonly) SZFriendsStrings *strings;
@property(nonatomic, readonly) SZFriendsAudience *audience;

- (NSString *)titleForPerson:(SZFriendsPersonFacts *)person;
- (NSString *)firstNameForPerson:(SZFriendsPersonFacts *)person;
- (NSDictionary<NSString *, id> *)avatarForPerson:(SZFriendsPersonFacts *)person;
- (NSDictionary<NSString *, id> *)avatarForPicture:(SZFriendsPicture *)picture
                                              seed:(NSString *)seed
                                       displayName:(NSString *)displayName;
- (NSDictionary<NSString *, id> *)routeForKind:(SZFriendsRouteKind)kind method:(SZFriendsRouteMethod)method;
- (nullable NSString *)spokenRouteForKind:(SZFriendsRouteKind)kind method:(SZFriendsRouteMethod)method;
// The back arrow toward the list. `thisRowWaits`: the view's own row waits too, so the count is "more".
- (NSDictionary<NSString *, id> *)backToFriendsWithCount:(NSInteger)count thisRowWaits:(BOOL)thisRowWaits;
- (NSDictionary<NSString *, id> *)footerWithProfile:(SZFriendsProfileFacts *)profile;
- (NSMutableDictionary<NSString *, id> *)action:(NSString *)action label:(NSString *)label style:(NSString *)style;
// A confirmation dialog from catalog keys filled with `values`; `destructive` draws its confirm button in the
// destructive color, since every confirmation Friends asks for ends something the person cannot get back.
- (NSDictionary<NSString *, id> *)confirmWithTitle:(NSString *)titleKey
                                              body:(NSString *)bodyKey
                                      confirmLabel:(NSString *)confirmKey
                                            values:(nullable NSDictionary<NSString *, NSString *> *)values
                                       destructive:(BOOL)destructive;
// Block as a button anywhere in the dropdown: destructive, and armed like the list row's, so it needs a second
// click within the same few seconds wherever it appears. `who` is the name the button says.
- (NSMutableDictionary<NSString *, id> *)blockActionNaming:(NSString *)who label:(NSString *)label;
// The name a person's avatar initials come from: their name, or their raw Friends ID (never the display form,
// whose U+2011 would hide the second word's initial).
- (NSString *)initialsSourceForName:(nullable NSString *)name friendsID:(nullable NSString *)friendsID;
- (BOOL)personWaits:(SZFriendsPersonFacts *)person;
// Remove's question for this person (remove_friend), as the row's menu and a friend's details ask it (+Rows).
- (NSDictionary<NSString *, id> *)removeConfirmForPerson:(SZFriendsPersonFacts *)person;
// The list row's menu, for clients that declared list.menu (+Rows).
- (NSArray<NSDictionary<NSString *, id> *> *)rowMenuForPerson:(SZFriendsPersonFacts *)person;
// The row with `found` for clients that declared nearby.found, and "Found over ..." at the end of its spoken label
// when something sees the person; the row as it was for other clients (+Rows).
- (NSDictionary<NSString *, id> *)row:(NSDictionary<NSString *, id> *)row
                     foundWithMethods:(nullable NSArray<NSNumber *> *)methods;
- (NSArray<SZFriendsPersonFacts *> *)peopleByLatestInteraction:(NSArray<SZFriendsPersonFacts *> *)people;
- (BOOL)name:(nullable NSString *)name friendsID:(nullable NSString *)friendsID matchesQuery:(NSString *)query;
- (NSDictionary<NSString *, id> *)emptyWithKind:(nullable NSString *)kind title:(NSString *)title
                                           body:(nullable NSString *)body;
@end

// How a friend shows connected (SZFriendsSnapshotBuilder+Routes.m): the route object, its line and the waiting words,
// from the facts' live route and, for an audience whose helper reaches friends online, the online attempts.
typedef NS_ENUM(NSInteger, SZFriendsShownRoute) {
    SZFriendsShownRouteNone = 0,    // nothing to show (a request by ID that never connected)
    SZFriendsShownRouteLocal,       // a nearby session is up
    SZFriendsShownRouteOnline,      // a session over the Internet is up, direct or through the relay
    SZFriendsShownRouteConnecting,  // no session; an online attempt is running
    SZFriendsShownRouteOffline,     // no session, and nothing says more
    SZFriendsShownRouteUnreachable, // no session; the last online attempt failed, relay included
};

@interface SZFriendsSnapshotBuilder (SZFriendsRoutes)
- (SZFriendsShownRoute)shownRouteForPerson:(SZFriendsPersonFacts *)person;
// PROTOCOL.md type.route for this person, and its label (nil for none) and spoken form.
- (NSDictionary<NSString *, id> *)routeForPerson:(SZFriendsPersonFacts *)person;
- (nullable NSString *)routeLabelForPerson:(SZFriendsPersonFacts *)person;
- (nullable NSString *)spokenRouteForPerson:(SZFriendsPersonFacts *)person;
// PROTOCOL.md type.route for a live session that is not with a friend (one of the person's own computers, a code
// being checked): nearby or online by its method; nil for None.
- (nullable NSDictionary<NSString *, id> *)routeForLiveMethod:(SZFriendsRouteMethod)method;
// The catalog key of something outgoing that is still waiting to go (`family` "message.status", "preview.status" or
// "transfer.status"): ".connecting" while an online attempt runs, ".queued_online" when friends are reached online
// too, ".queued" otherwise.
- (NSString *)waitingKeyInFamily:(NSString *)family person:(SZFriendsPersonFacts *)person;
// The composer's note about when things go, or nil while a session is up or being made.
- (nullable NSString *)composerReachNoteForPerson:(SZFriendsPersonFacts *)person;
@end

// The public builder methods forward to these, which live in the category files to keep each under the size cap.
@interface SZFriendsSnapshotBuilder (SZFriendsConversation)
- (NSDictionary<NSString *, id> *)buildConversationForPerson:(SZFriendsPersonFacts *)person
                                                       items:(NSArray<SZFriendsItemFacts *> *)items
                                                  hasEarlier:(BOOL)hasEarlier
                                             highlightItemID:(nullable NSString *)highlightItemID
                                            waitingElsewhere:(NSInteger)waitingElsewhere
                                                         now:(NSDate *)now;
@end

@interface SZFriendsSnapshotBuilder (SZFriendsNearby)
- (NSDictionary<NSString *, id> *)buildNearbyAccessWithFacts:(SZFriendsNearbyFacts *)nearby
                                                     profile:(SZFriendsProfileFacts *)profile;
- (NSDictionary<NSString *, id> *)buildNearbyWithFacts:(SZFriendsNearbyFacts *)nearby
                                              profile:(SZFriendsProfileFacts *)profile
                                                query:(NSString *)query
                                                  now:(NSDate *)now;
// When an empty Nearby stops saying it is looking (workingSince + SZFriendsNearbySearchingSeconds), if still ahead.
- (nullable NSDate *)searchingEndsWithFacts:(SZFriendsNearbyFacts *)nearby now:(NSDate *)now;
// The `empty` object when no person shows, or NSNull when nothing works or starts (the card above says it all).
// `filtered`: people are visible but the filter hides them all. `alert`: the network card is up, so "nobody" leaves
// out its body. Separate so tests reach each variant.
- (id)emptyForNearby:(SZFriendsNearbyFacts *)nearby
                                        filtered:(BOOL)filtered
                                           query:(NSString *)query
                                           alert:(BOOL)alert
                                             now:(NSDate *)now;
@end

@interface SZFriendsSnapshotBuilder (SZFriendsDetails)
- (NSDictionary<NSString *, id> *)buildDetailsForPerson:(SZFriendsPersonFacts *)person
                                       waitingElsewhere:(NSInteger)waitingElsewhere
                                                    now:(NSDate *)now;
- (NSDictionary<NSString *, id> *)buildProfileWithFacts:(SZFriendsProfileFacts *)profile
                                       waitingElsewhere:(NSInteger)waitingElsewhere;
@end

@interface SZFriendsSnapshotBuilder (SZFriendsSettings)
// The catalog key of a Delete history or Reset confirmation body for this audience (".assistant" when its AI chat
// may have quoted Friends chats).
- (NSString *)deletionBodyKey:(NSString *)key;
- (NSDictionary<NSString *, id> *)buildSettingsWithProfile:(SZFriendsProfileFacts *)profile
                                                    people:(NSArray<SZFriendsPersonFacts *> *)people;
- (NSDictionary<NSString *, id> *)buildSearchResultWithHits:(NSArray<SZFriendsSearchHitFacts *> *)hits
                                                     people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)people
                                                       more:(BOOL)more
                                                        now:(NSDate *)now;
@end

@interface SZFriendsStrings (SZFriendsMessages)
- (nullable NSString *)errorMessageForCode:(NSString *)code details:(NSDictionary<NSString *, id> *)details;
- (NSString *)addByIDMessageForID:(NSString *)friendsID;
@end

// A message's text as one person sees it, its mentions resolved against the builder's directory
// (SZFriendsSnapshotBuilder+Mentions.m, PROTOCOL.md § Mentions).
@interface SZFriendsResolvedText : NSObject
@property(nonatomic, copy) NSString *markdown;                // `text`: mentions as links to `mentions`, or literal
@property(nonatomic, copy) NSString *plain;                   // what a person reads, each mention as "@Name"
@property(nonatomic, copy) NSArray<NSDictionary *> *segments; // the plain-text form, a mention segment per link
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *mentions; // nil when no mention shows as a link
@end

@interface SZFriendsSnapshotBuilder (SZFriendsMentions)
- (SZFriendsResolvedText *)resolvedText:(NSString *)text;
// Only the words, for list previews.
- (NSString *)plainTextOf:(NSString *)text;
// A search hit as its excerpt shows it: the plain text, its matches moved there. Nil when every match was in what
// nobody sees (a mention's ID or key), so a search for "szfriends" or a key fragment finds nothing.
- (nullable SZFriendsSearchHitFacts *)displayedHit:(SZFriendsSearchHitFacts *)hit;
// The composer's `mention_note` and whether a list row is `mentionable`, or nil when the client shows no mentions.
- (nullable id)mentionNoteForPerson:(SZFriendsPersonFacts *)person enabled:(BOOL)enabled;
- (nullable NSNumber *)mentionableForPerson:(SZFriendsPersonFacts *)person;
@end

// Items of a conversation (SZFriendsSnapshotBuilder+Items.m).
@interface SZFriendsSnapshotBuilder (SZFriendsItems)
// Plain text split at the links a person can open (http, https, mailto).
- (NSArray<NSDictionary *> *)segmentsForText:(NSString *)text;
- (NSArray<NSDictionary<NSString *, id> *> *)itemsForPerson:(SZFriendsPersonFacts *)person
                                                      items:(NSArray<SZFriendsItemFacts *> *)items
                                            highlightItemID:(nullable NSString *)highlightItemID
                                                        now:(NSDate *)now;
- (NSDictionary<NSString *, id> *)buildMessageStatusWithMessages:(NSArray<SZFriendsItemFacts *> *)messages
                                                          people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)
                                                                     people;
@end

// Words items and list rows share (SZFriendsSnapshotBuilder+Previews.m).
@interface SZFriendsSnapshotBuilder (SZFriendsPreviews)
// The list row's subtitle and its spoken form for the item the row previews; `explainsRoute` is set when the
// subtitle already says the friend is not reachable (a queued item), so the row does not repeat the route.
- (NSString *)previewForItem:(nullable SZFriendsItemFacts *)item
                      person:(SZFriendsPersonFacts *)person
                      spoken:(NSString *_Nullable *_Nonnull)spoken
               explainsRoute:(BOOL *)explainsRoute;
- (nullable NSString *)eventTextForItem:(SZFriendsItemFacts *)item person:(SZFriendsPersonFacts *)person;
- (NSString *)spokenPhrase:(NSString *)phrase person:(SZFriendsPersonFacts *)person;
// `key` with a failure's own words when the catalog has them, else `key` itself.
- (NSString *)key:(NSString *)key forFailure:(nullable NSString *)failureReason person:(SZFriendsPersonFacts *)person;
// Whether Try again can still work for this failure toward this person.
- (BOOL)canRetryFailure:(nullable NSString *)failureReason person:(SZFriendsPersonFacts *)person;
// list_row drop_refusal for a row that refuses dragged files: why, or NSNull when the client takes no drops.
- (id)dropRefusalForPerson:(SZFriendsPersonFacts *)person;
@end

@interface SZFriendsSnapshotBuilder (SZFriendsLinksSection)
// The profile's "links" (SZFriendsSnapshotBuilder+Links.m): nil unless the audience's helper announces "links" and
// a friend link can be made.
- (nullable id)linksSectionWithFacts:(nullable SZFriendsLinksFacts *)links;
@end

NS_ASSUME_NONNULL_END
