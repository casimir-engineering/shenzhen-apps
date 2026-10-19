#pragma once
// What tools show in the AI chat besides messages: collapsible step rows ("Searching the web", "Running Python"),
// cards ("Sent to Mei" with the text, attachments, status and Cancel) and image outputs with Save.
//
// Entries are plain JSON dictionaries (keys below), saved with the chat under "activity" and never sent to the
// model: the model reads tool results, the person reads these. Each entry is anchored after the messages that
// existed when it was added, so it stays where it happened when the chat is reopened. Every value is validated and
// clipped on the way in and when a chat file is read, so a provider bug or an edited file cannot break the view.
//
// Actions (a step's Cancel, a card's Cancel or Open) run a handler that lives only as long as this chat stays open
// in this window. A reopened chat shows its entries without buttons, and an entry that was still running when the
// chat closed shows its interruptedStatus ("Stopped" unless the provider wrote something truer).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Entry keys.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityIDKey;          // assigned
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityKindKey;        // step, card or image
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityAnchorKey;      // assigned: message count when added
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityTitleKey;       // ≤ 200 characters
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityDetailKey;      // step detail, shown expanded; ≤ 4,000
// "code", or a language name such as "python": the detail is code, shown in the chat's code box with Copy and
// without wrapping. Absent: plain text.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityDetailStyleKey;
// What a step's run printed, shown expanded under its detail as printed, less one final line break: in a box
// captioned "output", monospace, unwrapped, no syntax colours, with Copy. ≤ 4,000.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityOutputKey;
// A sentence about the step for the person, shown expanded under its detail and output in wrapping 12 pt secondary
// text ("Charts aren’t shown for requests that include your Friends chats."). ≤ 400.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityNoteKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityBodyKey;        // card body, Markdown; ≤ 8,000
// SPDFMacAIActivityBodyStyleLiteral: the body is text the person approves before it leaves the Mac, so the card
// shows it as it will arrive: every character, wrapped, no Markdown, characters that draw nothing marked (see
// SPDFMacAIActivityVisibleText). A "friends.send" card is always shown this way. A literal body holds up to 32,768
// bytes of UTF-8, Friends' message limit, so AI chat and `/` refuse at one length; a longer one is refused (the card
// is not added), never cut short. Absent: Markdown.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityBodyStyleKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityCardKindKey;    // provider-defined ("friends.send"); not shown
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStateKey;       // running, done, failed or stopped
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStatusKey;      // reader-facing status line; ≤ 200
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityAttachmentsKey; // [{name, detail}], ≤ 16
// [{id, title, primary?}], ≤ 4; shown while a handler lives. primary: YES draws the one action the card waits for
// in the accent colour (Install); the id "install" is primary without saying so.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityActionsKey;
// [URL string or {url, title, host}], ≤ 16. An expanded step lists its https links, one per line: the title (or the
// address) opens it, the host (as given, else the address's) follows in the secondary colour unless the title is
// the host, and the address is the tooltip. http rows come after them, never as links: the title in plain text, the
// host in the secondary colour, and "Not a secure page" on a line of its own under them. Other schemes are not
// listed. A redacted entry keeps the addresses but not the titles.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityLinksKey;
// {path, caption}: a PNG in the chat's assets. The caption is shown under the picture and names the saved file: the
// model's description of the image when it gave one, else the file name.
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityImageKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityRequestOnlyKey; // YES: see SPDFMacAIActivityRequestOnly
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStoredNoticeKey;     // replaces a request-only body when saved
// Replaces a request-only entry's title when saved; ≤ 200. Set it whenever the title holds words the model wrote or
// the request read (a helper's task, a file the code named): "Helper", "Table from Python".
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStoredTitleKey;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityInterruptedStatusKey; // status if reopened while running

FOUNDATION_EXPORT NSString* const SPDFMacAIActivityKindStep;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityKindCard;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityKindImage;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStateRunning;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStateDone;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStateFailed;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityStateStopped;
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityActionCancel; // "cancel", the action id a step's Cancel uses
FOUNDATION_EXPORT NSString* const SPDFMacAIActivityBodyStyleLiteral; // "literal"

typedef NS_OPTIONS(NSUInteger, SPDFMacAIActivityOptions) {
    SPDFMacAIActivityOptionsNone = 0,
    // The entry holds content that may be kept only for the request that read it (Friends excerpts, brief § AI
    // boundaries). The chat file keeps its state, status, link addresses and its title (or its stored title); its
    // detail, output, note, body and attachments become the stored notice. Once the request ends, the open chat
    // shows the same, as Friends excerpts do. Without a notice of its own, an entry linking to Friends messages says
    // "The messages it read aren’t kept after this request, because it included your Friends chats.", and any other
    // "Not kept after this request, because it included your Friends chats."
    SPDFMacAIActivityRequestOnly = 1 << 0,
};

typedef void (^SPDFMacAIActivityHandler)(NSString* actionID);

// What a provider uses, through SPDFMacAIRequestContext.activity. Main thread only.
@protocol SPDFMacAIActivityReporting <NSObject>
// A running step. With `cancel`, the row shows Cancel while it runs (the handler receives "cancel").
- (nullable NSString*)beginStepWithTitle:(NSString*)title detail:(nullable NSString*)detail
                                 options:(SPDFMacAIActivityOptions)options cancel:(nullable dispatch_block_t)cancel;
// A card. `card` holds the card keys (title, body, cardKind, status, state, attachments, actions, links,
// interruptedStatus); `handler` runs its actions.
- (nullable NSString*)addCard:(NSDictionary*)card options:(SPDFMacAIActivityOptions)options
                      handler:(nullable SPDFMacAIActivityHandler)handler;
// Copies the PNG at `path` into the chat's own storage (≤ 8 MB) and shows it with Save. The caller keeps and
// deletes its own file. nil when the image could not be kept.
- (nullable NSString*)addImageAtPath:(NSString*)path caption:(NSString*)caption
                             options:(SPDFMacAIActivityOptions)options;
// Merges `changes` (any entry keys except id, kind, anchor and image). A state other than running ends the
// entry's handler unless `changes` carries actions again.
- (void)updateEntry:(NSString*)identifier changes:(NSDictionary*)changes;
- (void)setHandler:(nullable SPDFMacAIActivityHandler)handler forEntry:(NSString*)identifier;
@end

// The chat's activity: owned by SPDFMacAIChatSession, which saves `entries` with the chat.
@interface SPDFMacAIChatActivity : NSObject <SPDFMacAIActivityReporting>
// The message count new entries anchor after; called on each add.
@property(nonatomic, copy, nullable) NSUInteger (^anchor)(void);
// Saves a PNG for the chat ({path, caption} in, the saved {path, caption} out), or nil.
@property(nonatomic, copy, nullable) NSDictionary* _Nullable (^saveImage)(NSDictionary* image);
@property(nonatomic, copy, nullable) void (^changed)(void);
@property(nonatomic, readonly, copy) NSArray<NSDictionary*>* entries;
// Replaces every entry (a chat opened or started) and drops every handler. Entries are validated; one still
// running becomes stopped with its interrupted status.
- (void)loadEntries:(nullable id)entries;
// Replaces entries with what the chat file keeps, keeping handlers for entries that remain (the request ended).
- (void)adoptStoredEntries:(NSArray<NSDictionary*>*)entries;
// The request ended: steps still running become stopped, say their interrupted status ("Stopped" by default) instead
// of their progress, and lose Cancel. Cards keep their state and actions, because what they show (a queued send) can
// outlive the request.
- (void)endRunningSteps;
// The actions the view may show for an entry: those whose handler is still alive in this window.
- (NSArray<NSDictionary*>*)liveActionsForEntry:(NSString*)identifier;
- (BOOL)performAction:(NSString*)actionID forEntry:(NSString*)identifier;
@end

// The entries as the chat file keeps them (request-only content replaced by its stored notice).
NSArray<NSDictionary*>* SPDFMacAIActivityEntriesForStorage(NSArray<NSDictionary*>* entries);
// A validated, clipped copy of an entry read from anywhere, or nil.
NSDictionary* _Nullable SPDFMacAIActivitySanitizedEntry(id entry);
// The reader-facing status for an entry: its own status, else one for its state ("Done", "Stopped").
NSString* SPDFMacAIActivityStatusText(NSDictionary* entry);
// YES when a card's body must be shown literally (SPDFMacAIActivityBodyStyleKey, or a "friends.send" card).
BOOL SPDFMacAIActivityBodyIsLiteral(NSDictionary* entry);
// `text` as a person approving it must see it, composed (NFC) as the send side composes it: each character that
// draws nothing on screen, yet would be sent (zero-width and joining characters, direction overrides, tag and
// variation characters, fillers, the braille blank, other controls), and each private-use character, becomes a visible
// "‹U+200B›" marker. Joiners and selectors that change what is drawn stay as they are, by the rule the send check also
// applies (ai-agent-capabilities.md § 1): a non-joiner between Arabic or Indic letters, a joiner inside an emoji
// (between Extended_Pictographic characters, never after a marked selector) or an Indic conjunct (beside a virama,
// next to a consonant of its block), one presentation selector right after a base of Unicode's emoji variation
// sequences (a keycap base only before U+20E3). A combining mark its letter already carries, or a fifth on one letter,
// is marked too, since repeats of some marks draw nothing more, and so is a mark of another script than its letter's
// (a Quranic pause or annotation mark may stand on a space). Every
// implementation runs the cases in friends/fixtures/text/invisible-cases.json. `markers` receives each marker's range
// in the result, and is empty when nothing was marked.
NSString* SPDFMacAIActivityVisibleText(NSString* text, NSArray<NSValue*>* _Nullable* _Nullable markers);

NS_ASSUME_NONNULL_END
