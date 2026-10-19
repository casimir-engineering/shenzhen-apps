// Shenzhen Friends host adapter contract: everything the Friends views need from the app that hosts them.
//
// One small interface, so ShenzhenPDF (its adapter lives in portable/mac/) and later any other AppKit host plug in
// without Friends knowing anything about them (brief § Containment and porting, host adapter contract):
//   - where the Friends button goes (the dropdown carries everything else);
//   - items for `#`, each bound to an exact revision;
//   - pasteboard types to accept beyond file URLs (ShenzhenPDF: its tab drag type);
//   - which formats it opens in place, and how it opens or imports a received file;
//   - optionally, an assistant for `/`, and the services Friends exports to it (global search, citations,
//     scoped chat questions);
//   - optionally, Markdown rendering for messages that carry it;
//   - appearance tokens, so the views match the host's chrome.
// Shenzhen Files (GTK4) implements the same contract in C against its GTK views; this is the AppKit binding.
//
// Hidden from the host's assistant: every Friends view the host receives or places (the title button, the
// dropdown, the Settings section) and every alert or panel Friends opens carries an identifier starting with
// "szfriends.", on the view itself or on an ancestor, and on the window for alerts and panels. A host whose
// assistant can inspect or operate the app's controls must skip anything so marked, so the assistant never sees
// or presses Friends without an @ scope (brief § AI boundaries).
//
// Called on the main thread unless a method says otherwise.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Appearance tokens

// Concrete fonts, colors and metrics from the host's own chrome. Colors may be dynamic (they follow the
// window's appearance); the views never hard-code a color the host can supply. -init fills every property with
// ShenzhenPDF's light and dark chrome values, so a host overrides only what differs and a property added in a
// later version is never nil for a host written before it.
@interface SZFriendsAppearance : NSObject
@property(nonatomic, strong) NSFont *bodyFont;         // rows, messages: 13 pt in ShenzhenPDF
@property(nonatomic, strong) NSFont *secondaryFont;    // subtitles, times: 12 pt
@property(nonatomic, strong) NSFont *captionFont;      // section headers, badges: 11 pt
@property(nonatomic, strong) NSFont *headerFont;       // centered view titles: 13 pt semibold
@property(nonatomic, strong) NSColor *backgroundColor;
@property(nonatomic, strong) NSColor *fieldBackgroundColor;
@property(nonatomic, strong) NSColor *separatorColor;
@property(nonatomic, strong) NSColor *primaryTextColor;
@property(nonatomic, strong) NSColor *secondaryTextColor;
@property(nonatomic, strong) NSColor *accentColor;          // primary buttons, links, progress
@property(nonatomic, strong) NSColor *selectionColor;       // highlighted row, drop target
// The fill under the pointer (rows, plain and icon buttons). Never the selection colour: in ShenzhenPDF that marks
// the selected chapter or chat, so a hovered row tinted with it reads as selected (#e8ebed / #393d42).
@property(nonatomic, strong) NSColor *hoverColor;
@property(nonatomic, strong) NSColor *outgoingBubbleColor;
@property(nonatomic, strong) NSColor *incomingBubbleColor;
@property(nonatomic, strong) NSColor *badgeColor;
@property(nonatomic, strong) NSColor *badgeTextColor;
@property(nonatomic, strong) NSColor *localRouteColor;
@property(nonatomic, strong) NSColor *onlineRouteColor;
@property(nonatomic, strong) NSColor *offlineRouteColor;
@property(nonatomic, strong) NSColor *destructiveColor;     // Block
@property(nonatomic, strong) NSColor *controlColor;         // secondary buttons, the tab track, fields' fill
@property(nonatomic, strong) NSColor *controlBorderColor;   // secondary buttons' outline
@property(nonatomic, strong) NSColor *primaryButtonColor;   // Accept, Send, Request
@property(nonatomic, strong) NSColor *primaryButtonTextColor;
@property(nonatomic, strong) NSColor *successColor;         // verified, delivered
@property(nonatomic, strong) NSColor *warningColor;         // the one prominent Nearby card, a changed ID
// The Friends button's icon in the title bar, the color of the host's other title-bar icons so they read as one
// row (ShenzhenPDF: Groups and Search, #26282b / #eceef1).
@property(nonatomic, strong) NSColor *titleBarIconColor;
@property(nonatomic) CGFloat titleBarButtonSize;            // the Friends button's square side, 28 pt
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) CGFloat dropdownWidth;                 // about 400 pt
@property(nonatomic) CGFloat dropdownMaxHeight;             // fits the window, up to 640 pt
@end

#pragma mark - Attachments

// One file the host can attach: a `#` picker entry, or a tab dragged from the host. Selecting or dropping it
// binds the exact revision shown; attaching transmits nothing until Send.
@interface SZFriendsAttachableItem : NSObject
@property(nonatomic, copy) NSString *title;      // "Supplier contract v3.pdf"
@property(nonatomic, copy) NSString *detail;     // "Open in this window · version saved today, 14:02"
@property(nonatomic, copy) NSString *kindLabel;  // "PDF"
@property(nonatomic, copy) NSURL *fileURL;       // readable file holding exactly that revision's bytes
// PROTOCOL.md file.revision object (source, document_id, revision_id, label, sha256, size), or nil for a
// plain file whose current bytes are what the person means.
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *revision;
@end

#pragma mark - Optional Markdown rendering

// A message whose item carries text_format "markdown" is drawn from -friendsRenderMarkdown:width:appearance: (on
// SZFriendsHost below): the host's own Markdown engine at chat scale, so friend messages read like the host's
// documents. The returned string must be:
//   - laid out for `width` points. Text wraps at it. A block that keeps its natural width (a table, a diagram, a
//     line of code that must not wrap) is ONE NSTextAttachment on a paragraph of its own, at the block's natural
//     size (its bounds, else its image's, else its cell's); wider than `width`, it scrolls sideways in the bubble.
//   - drawn in concrete colours for `appearance` (light or dark). The bubble asks again when either changes, and
//     caches the answer per width and appearance.
//   - safe for untrusted text: links only where they may go (the views open https, http and mailto, nothing else),
//     no image fetched without a click, no raw HTML run, and diagram and math layout inside their deadlines. It is
//     called on the main thread while the conversation lays out.
//   - mentions kept: a link whose destination is szfriends:mention?ref=<n> keeps that destination, character for
//     character, as its NSLinkAttributeName. The views draw it as the item's mention whose url and label it matches
//     and act on it (open that friend's chat, or a stranger's card); any other szfriends: link shows as its words.
//     A host that drops such links shows mentions in its renderings as plain "@Name". The views keep a message whose
//     only Markdown is its mentions away from the host altogether and draw its plain segments as links.
// Copying: the whole message copies its Markdown source exactly. A part copies as shown, except that a range marked
// with SZFriendsMarkdownSourceAttributeName (an NSString) copies as that string, once, if any of it is selected: mark
// what is drawn rather than written out (a formula, a diagram, a table, an image placeholder) with its source.
// An attachment without an image is drawn through its cell and gets its clicks through it (-wantsToTrackMouseFor
// Event:..., then -trackMouse:...), in the bubble's text or, for a wide block, in its sideways strip.
// When a rendering changes later (an image the person asked to load arrives), post
// SZFriendsMarkdownDidChangeNotification on the main thread with that message's Markdown as the object: bubbles
// showing it ask again.
// nil, or a host without the method (Shenzhen Files may have none), shows the item's plain segments instead. A nil
// answer must stay cheap to show, since it is what a spent allowance (below) falls back to: the views measure plain
// text once per width and appearance and lay out at most its first 4,096 characters, with the helper's Show all
// (welcome.strings show_all) under it for the rest.
// Render passes: every layout of a conversation's messages (opening it, a new snapshot, an appearance change) is
// bracketed by -friendsBeginMarkdownPass and -friendsEndMarkdownPass, so the host can share ONE time allowance across
// all the renders in between (ShenzhenPDF: 1 s, on top of each message's own 0.4 s) and answer nil once it is spent.
// WHY: a per-message limit alone lets fifty hostile messages freeze the window for fifty limits each time the
// conversation opens. The views ask for the newest messages first, so what falls back to plain text is the oldest,
// and they keep that answer for that width and appearance, so a spent pass is not paid for again on the next one.
// While the conversation's width keeps changing (a live resize), they lay each message's last answer out again at the
// new width and ask nothing; they ask once more when the width settles (the live resize ends, or 0.3 s pass without a
// change). Passes never nest, and each begin has its end before the views return to the run loop.
extern NSAttributedStringKey const SZFriendsMarkdownSourceAttributeName; // "SZFriendsMarkdownSource"
extern NSNotificationName const SZFriendsMarkdownDidChangeNotification;
// Links the host draws itself, such as one in a table drawn as an attachment, open only through the Friends link menu,
// as every other link in a friend's message does: call this from the click with the view it landed in (the bubble's
// text view or a wide block's strip, or a view inside either), the link, the words it shows and the point in `view`
// to show the menu at. The menu names where the link goes, warns first when `words` show another site, and only its
// last item opens the link. Nothing shows for a view outside a Friends message or a link Friends never opens (only
// https, http and mailto do).
FOUNDATION_EXTERN void SZFriendsShowLinkMenuInView(NSView *view, NSURL *url, NSString *words, NSPoint point);

#pragma mark - Optional assistant

// `/` in a friend conversation: the person types a command for the host's assistant into the composer. A command
// never sends by itself, because it may read the friend's chat and only the person's own Send may send what came of
// that. It either prepares a draft, which fills the composer, or, when the command asks to send, proposes a message:
// the views show it above the composer exactly as Friends will deliver it, with Send and Edit, and only the
// person's press of that Send calls the host's `send` (send_message with via_assistant), so the message arrives in
// the history with its assistant_label. Agent output never adds recipients, and attachments come only from the
// person's own `#` chips or drops (brief § Interface, § AI boundaries).
typedef NS_ENUM(NSInteger, SZFriendsAssistantOutcome) {
    SZFriendsAssistantOutcomeDraft = 0, // `text` and `attachments` fill the composer; nothing was sent
    // Kept so hosts written before proposals still compile; a host following this contract never returns it. The
    // views treat it as already sent: `attachments` are the chips that went with it and leave the composer.
    SZFriendsAssistantOutcomeSent,
    // A message the command asked to send, waiting for the person: `text` and `attachments` show above the composer
    // with Send and Edit; Send calls `send`, Edit moves them into the composer as a draft. Without `send`, from an
    // assistant without proposalEditLabel, or with a file that did not come from the person's chips (which the card
    // would not show, yet `send` would send), the views fill the composer as with a draft instead.
    SZFriendsAssistantOutcomeProposed,
};

@interface SZFriendsAssistantResult : NSObject
@property(nonatomic) SZFriendsAssistantOutcome outcome;
// The draft, or the proposed message exactly as `send` delivers it. A proposal is shown character for character as
// plain wrapping text: no Markdown is drawn, nothing is folded away, and characters that draw nothing (zero-width,
// direction overrides, controls) show as their code point, so what the person approves is all that goes.
@property(nonatomic, copy) NSString *text;
// Only items the person attached for this command (passed to -runCommand:), or items cut from them (pages of a
// chipped document, matched by revision source and document_id). The views drop anything else.
@property(nonatomic, copy) NSArray<SZFriendsAttachableItem *> *attachments;
// Optional, written for the person: shown above the composer with a draft and at the top of a proposal (ShenzhenPDF
// says "Not sent yet. Check it, then press Send." for both), and spoken to VoiceOver when either arrives. nil says
// nothing.
@property(nonatomic, copy, nullable) NSString *note;
// Proposed only: queues exactly `text` with `attachments` to this conversation's friend, marked via_assistant, and
// calls `done` once on the main thread, with nil once Friends has the message or an error whose localizedDescription
// is written for the person. The views call it only from the person's press of Send, never twice at once; after a
// failure the person may press Send again, which calls it again.
@property(nonatomic, copy, nullable) void (^send)(void (^done)(NSError *_Nullable error));
@end

@protocol SZFriendsAssistantTask <NSObject>
- (void)cancel; // stops the work; the completion then never runs
@end

@protocol SZFriendsAssistant <NSObject>
// The command field's words. They name what this host's assistant can do, so like the `#` placeholder they come
// from the host, not the helper's catalog.
@property(nonatomic, readonly, copy) NSString *commandLabel;       // the tag the field starts with: "Ask the assistant"
// What a command can ask for. Not "send it": a command proposes, and the person sends.
@property(nonatomic, readonly, copy) NSString *commandPlaceholder; // "Draft a reply or summarize a document"
// One `/` request. `conversationID` may be read through the scope the host opens for this request only, and is the
// only friend a proposal may go to. `attachments` are the composer's chips when the person ran the command.
// `progress` says what is happening, for the person ("Reading pages 3–5…"). Completion runs once, on the main
// thread, with a result or an error whose localizedDescription is written for the person; neither runs after -cancel.
- (id<SZFriendsAssistantTask>)runCommand:(NSString *)command
                          conversationID:(NSString *)conversationID
                             attachments:(NSArray<SZFriendsAttachableItem *> *)attachments
                                progress:(void (^)(NSString *status))progress
                              completion:(void (^)(SZFriendsAssistantResult *_Nullable result,
                                                   NSError *_Nullable error))completion;
@optional
// Under the command field while the person writes a command (not while it runs): what the assistant reads for it
// and where that goes, for someone deciding whether to run it ("With this command, the assistant may read this chat
// and your documents. …"). It wraps; empty or absent shows nothing.
@property(nonatomic, readonly, copy) NSString *commandNote;
// A proposal's own words; its Send button uses the composer's Send label, since it is the same send to this friend.
@property(nonatomic, readonly, copy) NSString *proposalEditLabel;     // "Edit": moves the message into the composer
@property(nonatomic, readonly, copy) NSString *proposalSendingStatus; // "Sending…" beside the spinner; absent: none
@end

#pragma mark - What Friends exports to the host

// One result for the host's global search (ShenzhenPDF: Cmd+K): conversation, time and matching context.
@interface SZFriendsSearchResult : NSObject
@property(nonatomic, copy) NSString *conversationID;
@property(nonatomic, copy) NSString *messageID;
@property(nonatomic, copy) NSString *conversationTitle;
@property(nonatomic, copy) NSString *timeLabel;
@property(nonatomic, copy) NSString *senderLabel;
// PROTOCOL.md rich text: segments with "text" and optional "match", so the host bolds matches without offsets.
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *excerpt;
@end

// Scoped access to Friends chats for ONE assistant request that explicitly brought them in (`@Mei`, `@All
// Friends chats`, or `/` inside a conversation). Every call is limited to the scope; the scope ends with the
// request. A request without one never gets this object, so it has no Friends tools at all.
typedef void (^SZFriendsScopeSearchCompletion)(NSArray<NSDictionary<NSString *, id> *> *results,
                                               NSError *_Nullable error);
typedef void (^SZFriendsScopeReadCompletion)(NSDictionary<NSString *, id> *_Nullable excerpt, NSError *_Nullable error);

@protocol SZFriendsChatScope <NSObject>
// PROTOCOL.md result.assistant_search results and result.assistant_read, as parsed dictionaries.
- (void)searchFor:(NSString *)query completion:(SZFriendsScopeSearchCompletion)completion;
- (void)readAroundMessage:(NSString *)messageID completion:(SZFriendsScopeReadCompletion)completion;
- (void)close;
@end

@protocol SZFriendsServices <NSObject>
// Local only; never touches the network.
- (void)searchMessages:(NSString *)query
                 limit:(NSUInteger)limit
            completion:(void (^)(NSArray<SZFriendsSearchResult *> *results))completion;
// Opens the dropdown at the highlighted message: Cmd+K results and assistant citations.
- (void)showMessage:(NSString *)messageID inConversation:(NSString *)conversationID;
// `conversationIDs` nil means All Friends chats. Completion runs once, with a scope or an error.
- (void)openChatScopeForConversations:(nullable NSArray<NSString *> *)conversationIDs
                           completion:(void (^)(id<SZFriendsChatScope> _Nullable scope,
                                                NSError *_Nullable error))completion;
@end

#pragma mark - The adapter

@protocol SZFriendsHost <NSObject>
@required
// hello.client (PROTOCOL.md § Handshake).
@property(nonatomic, readonly, copy) NSString *friendsAppID;      // "com.intuition.shenzhenpdf"
@property(nonatomic, readonly, copy) NSString *friendsAppName;    // "ShenzhenPDF"
@property(nonatomic, readonly, copy) NSString *friendsAppVersion;
@property(nonatomic, readonly, copy) NSString *friendsRevealInName; // "Finder"
// This app's embedded helper executable (Contents/Helpers/...), spawned when no helper is running.
@property(nonatomic, readonly, copy) NSString *friendsHelperPath;

// Placement: insert the button in the title bar (ShenzhenPDF: between Groups and Search) with one contiguous
// hit area, leaving the surrounding title-bar space draggable. Remove it when Friends is disabled.
- (void)friendsInstallButton:(NSView *)button;
- (void)friendsRemoveButton:(NSView *)button;

// Drag and drop beyond file URLs and file promises, which Friends handles itself. The button registers for both
// and for these types and spring-loads (NSSpringLoadingDestination): a drag hovering on it opens the dropdown on
// the list so the drop can land on a row; released on the button itself it opens "Send 2 files to…". The host
// keeps its own title-bar drag handling (window dragging, tab reordering) off the button's frame and leaves
// `springLoaded` as the button sets it; -friendsButtonAcceptsDrag: below lets it veto a drag it is handling.
- (NSArray<NSPasteboardType> *)friendsExtraPasteboardTypes;
// Resolves the host's own drag types (a reader tab: its file and the exact revision on screen). Empty when the
// pasteboard holds nothing of the host's.
- (NSArray<SZFriendsAttachableItem *> *)friendsItemsFromPasteboard:(NSPasteboard *)pasteboard;

// `#`: items matching `query` (ShenzhenPDF: open and Collection documents), best first. May complete later.
- (void)friendsAttachableItemsMatching:(NSString *)query
                            completion:(void (^)(NSArray<SZFriendsAttachableItem *> *items))completion;
// The `#` picker's search placeholder, which names what the host offers ("Search open and Collection
// documents"); host-specific, so it cannot come from the helper's catalog.
@property(nonatomic, readonly, copy) NSString *friendsAttachPlaceholder;

// Received files: lowercase extensions opened in place (hello.open_formats); Open for those, Show in Finder for
// the rest. Opening goes through the host's own rules (ShenzhenPDF: Collection consent and capture) and never
// overwrites a source.
@property(nonatomic, readonly, copy) NSSet<NSString *> *friendsFormatsOpenedInPlace;
- (void)friendsOpenReceivedFileAtURL:(NSURL *)fileURL;
- (void)friendsRevealFileAtURL:(NSURL *)fileURL;

- (SZFriendsAppearance *)friendsAppearance;

@optional
// Absent: `/` is hidden and hello omits "assistant.drafts" (Assistant track).
- (nullable id<SZFriendsAssistant>)friendsAssistant;
// Absent or nil: a Markdown message shows its plain segments. The contract is under "Optional Markdown rendering".
- (nullable NSAttributedString *)friendsRenderMarkdown:(NSString *)markdown
                                                 width:(CGFloat)width
                                            appearance:(NSAppearance *)appearance;
// One render pass (same section): renders between these share one allowance. Called only when both exist.
- (void)friendsBeginMarkdownPass;
- (void)friendsEndMarkdownPass;
// Implemented: hello carries "search.export", and Friends hands the host its services once connected (and
// withdraws them on disconnect or disable). Cmd+K uses -searchMessages: and -showMessage:.
- (void)friendsServicesDidBecomeAvailable:(id<SZFriendsServices>)services;
- (void)friendsServicesDidBecomeUnavailable;
// YES only once the host's AI tool layer registers Friends tools for scoped requests (Assistant track): hello then
// carries "assistant.chats" and -openChatScopeForConversations: works. Absent or NO: scopes fail with not_allowed,
// so an M1 host that exports search does not also claim chat access.
@property(nonatomic, readonly) BOOL friendsAssistantReadsChats;
// The files the host's own drag types on `pasteboard` would send, without resolving or hashing them (asked on every
// draggingEntered): links, folders and special files as they are, so the drag is refused as the same files from
// Finder are; files that no longer exist left out. Empty: nothing to send. Absent: the host's types are accepted by
// their presence and resolved on the drop.
- (NSArray<NSURL *> *)friendsDraggedFileURLsFromPasteboard:(NSPasteboard *)pasteboard;
// Absent or YES: the Friends button highlights and spring-loads for any drag carrying files or the host's types.
// NO for a drag the host is handling itself (a tab being reordered inside its own tab strip), so passing over the
// button on the way does not spring the dropdown open.
- (BOOL)friendsButtonAcceptsDrag:(id<NSDraggingInfo>)draggingInfo;
// Download links (PROTOCOL.md § Links). Both present: while the helper announces `links`, "Send 1 file to…" (one file
// dropped on the button) carries a link with this label ("Copy link instead"), and pressing it hands the host the
// file, then ends the picker. The host shows its expiry choice at `view` (its own words, as in its menus) and copies
// the link with -[SZFriendsDropdownController copyDownloadLinkForItem:expiresDays:completion:].
@property(nonatomic, readonly, copy) NSString *friendsCopyLinkInsteadLabel;
- (void)friendsOfferDownloadLinkForItem:(SZFriendsAttachableItem *)item fromView:(NSView *)view;
@end

NS_ASSUME_NONNULL_END
