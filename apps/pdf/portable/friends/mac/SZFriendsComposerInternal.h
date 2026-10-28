// Shenzhen Friends composer: its text view and the `/` assistant command (internal).

#import "mac/SZFriendsConversationPage.h"

NS_ASSUME_NONNULL_BEGIN

// Return and Enter send unless Shift is held or an input method is composing (Chinese, Japanese input must be
// able to confirm a candidate with Return). Escape goes to the dropdown, which closes the innermost picker first.
@interface SZFriendsComposerTextView : NSTextView
@property(nonatomic, copy) NSString *placeholder;
@property(nonatomic, strong) NSColor *placeholderColor;
@property(nonatomic) CGFloat placeholderIndent; // the `/` tag's room at the start of the first line
@property(nonatomic, copy, nullable) void (^onReturn)(void);
@property(nonatomic, copy, nullable) void (^onHash)(void);
// Up, Down and Return (without Shift) as moveUp:, moveDown: and insertNewline:, offered first to an open `#` picker:
// YES when it took the key.
@property(nonatomic, copy, nullable) BOOL (^onPickerKey)(SEL command);
@property(nonatomic, copy, nullable) void (^onAt)(void); // `@` where a word starts, as `#`
// `/` typed into an empty field: YES when it opened the command field, and the `/` is then not inserted.
@property(nonatomic, copy, nullable) BOOL (^onSlash)(void);
// Delete with nothing before the insertion point: YES when it was handled (it closes an empty command field).
@property(nonatomic, copy, nullable) BOOL (^onDeleteAtStart)(void);
// Paste (Cmd+V, Edit > Paste) reads `pasteboard`: the context's, the general pasteboard unless a test gives its own.
// `onPaste` answers YES when the composer took what it holds as attachments; NO pastes it as text.
// `canPasteAttachments` keeps Paste enabled for a pasteboard holding only an image or files.
@property(nonatomic, strong, nullable) NSPasteboard *pasteboard;
@property(nonatomic, copy, nullable) BOOL (^onPaste)(NSPasteboard *pasteboard);
@property(nonatomic, copy, nullable) BOOL (^canPasteAttachments)(NSPasteboard *pasteboard);
@end

// What the command controller and the attachment pickers (SZFriendsComposerAttach.m) need of the composer.
@interface SZFriendsComposerView ()
- (void)showError:(nullable NSString *)message;
- (void)saveDraft;
- (void)changedHeight;
@property(nonatomic, readonly) SZFriendsContext *composerContext;
// Enabled, not sending, and the helper takes files in this conversation (composer.accepts_drops).
@property(nonatomic, readonly) BOOL takesAttachments;
@end

// Attach files and Paste: chips, never an immediate send (SZFriendsComposerAttach.m).
@interface SZFriendsComposerView (SZFriendsAttach)
- (void)connectPickers; // the text view's `#`, `@` and picker keys, at init
- (void)chooseFilesToAttach; // the paperclip: the context's chooseFiles, then chips
// Files chosen, pasted or dropped, judged by `verdict`: a refusal shows in the helper's words (drop_folders_refused,
// drop_not_a_file) and attaches nothing; otherwise the items not attached yet become chips.
- (void)attachItems:(NSArray<SZFriendsAttachableItem *> *)items verdict:(SZFriendsDropVerdict)verdict;
// Paste from `pasteboard`: YES when it holds files, an image or the host's items, which become chips (or a refusal
// shows); NO when it is text for the field.
- (BOOL)pasteAttachmentsFromPasteboard:(NSPasteboard *)pasteboard;
- (BOOL)canPasteAttachmentsFromPasteboard:(NSPasteboard *)pasteboard;
@end

// An item the assistant may hand back: one of the person's chips, or cut from one (pages of the same document).
BOOL SZFriendsAssistantItemComesFrom(SZFriendsAttachableItem *item, NSArray<SZFriendsAttachableItem *> *chips);
// The result's attachments the composer may add as chips: from the chips the command ran with, and not there already.
NSArray<SZFriendsAttachableItem *> *SZFriendsAssistantDraftAdditions(SZFriendsAssistantResult *result,
                                                                     NSArray<SZFriendsAttachableItem *> *chipsWhenRun,
                                                                     NSArray<SZFriendsAttachableItem *> *chipsNow);

// `text` as a proposal shows it (SZFriendsLiteralText.m), composed (NFC) as Friends delivers it: every character as
// itself in `font` and `color`, except characters that draw nothing or reorder their neighbours, and a combining mark
// its letter already carries or that would be a fifth on it, shown as their code point ("U+200B", a run as
// "U+200B ×40") in `markColor` on a faint fill. Plain wrapping text: no links, no attachments.
NSAttributedString *SZFriendsLiteralText(NSString *text, NSFont *font, NSColor *color, NSColor *markColor);
BOOL SZFriendsCharacterDrawsNothing(UTF32Char character);
// The code points of the composed text that SZFriendsLiteralText shows as marks, in order, one entry per occurrence.
NSArray<NSNumber *> *SZFriendsLiteralMarkedCodePoints(NSString *text);
// Unicode's emoji and joining data (SZFriendsEmojiTables.m, written by tools/generate-emoji-tables.py) and its
// version: emoji variation bases and Extended_Pictographic; Joining_Type D and R; Indic_Syllabic_Category Consonant;
// and, for an Indic_Syllabic_Category Virama, the block it is in (NO for any other character).
extern NSString *const SZFriendsEmojiTablesUnicodeVersion;
BOOL SZFriendsIsEmojiVariationBase(UTF32Char character);
BOOL SZFriendsIsExtendedPictographic(UTF32Char character);
BOOL SZFriendsIsDualJoining(UTF32Char character);
BOOL SZFriendsIsRightJoining(UTF32Char character);
BOOL SZFriendsIsIndicConsonant(UTF32Char character);
BOOL SZFriendsViramaBlock(UTF32Char character, UTF32Char *low, UTF32Char *high);
// Whether a combining mark is drawn on a letter of its own script: the mark's Script_Extensions (else its Script)
// share a script with the letter's, or the mark belongs to no script in particular (Inherited, no extensions).
BOOL SZFriendsMarkFitsLetter(UTF32Char mark, UTF32Char letter);

@class SZFriendsAssistantProposal;

// Told when a proposal it shows changes (SZFriendsComposerCommand, while its composer shows that conversation).
@protocol SZFriendsProposalObserver <NSObject>
- (void)proposalDidChange:(SZFriendsAssistantProposal *)proposal; // started or failed sending
- (void)proposalWasSent:(SZFriendsAssistantProposal *)proposal;   // Friends has it; the card goes
@end

// A message a `/` command proposed (SZFriendsAssistantOutcomeProposed), held by the context per conversation until
// Friends has it or the person presses Edit, so a send under way finishes even when its composer is gone.
@interface SZFriendsAssistantProposal : NSObject
- (instancetype)initWithResult:(SZFriendsAssistantResult *)result
                  chipsWhenRun:(NSArray<SZFriendsAttachableItem *> *)chips
                conversationID:(NSString *)conversationID;
@property(nonatomic, strong, readonly) SZFriendsAssistantResult *result;
@property(nonatomic, copy, readonly) NSArray<SZFriendsAttachableItem *> *chipsWhenRun;
@property(nonatomic, copy, readonly) NSString *conversationID;
// What goes with the message: the result's attachments that came from the person's chips (the views drop others).
@property(nonatomic, copy, readonly) NSArray<SZFriendsAttachableItem *> *attachments;
@property(nonatomic, readonly) BOOL sending;
@property(nonatomic, copy, readonly) NSString *problem; // the host's words after a failed send; "" otherwise
@property(nonatomic, weak, nullable) id<SZFriendsProposalObserver> observer;
// The person pressed Send: calls the result's `send` once (nothing while one is under way). On success the proposal
// leaves the context. Its files left the composer, or the draft, when it arrived: they show on the card instead.
- (void)sendInContext:(SZFriendsContext *)context;
@end

// The card above the composer showing a proposal: the host's note, the message as literal wrapping text (vertical
// scrolling only, never sideways), the files going with it, Edit and Send, and while sending a spinner with the
// host's status, or after a failure the host's words.
@interface SZFriendsProposalView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, strong, nullable) SZFriendsAssistantProposal *proposal; // nil hides the card
@property(nonatomic, copy) NSString *sendLabel;                                // the composer's own Send label
@property(nonatomic) BOOL enabled;                                             // the composer's: Send needs it
@property(nonatomic, strong, readonly) NSTextField *noteLabel;
@property(nonatomic, strong, readonly) NSScrollView *textScroll;
@property(nonatomic, strong, readonly) NSTextView *textView;
@property(nonatomic, copy, readonly) NSArray<NSView *> *fileViews; // one per attachment, its title as its label
@property(nonatomic, strong, readonly) NSTextField *statusLabel;
@property(nonatomic, strong, readonly) NSProgressIndicator *spinner;
@property(nonatomic, strong, readonly) SZFriendsButton *editButton;
@property(nonatomic, strong, readonly) SZFriendsButton *sendButton;
@property(nonatomic, copy, nullable) void (^onEdit)(void);
@property(nonatomic, copy, nullable) void (^onSend)(void);
- (void)refresh; // the proposal's state changed: sending, its problem
- (CGFloat)heightForWidth:(CGFloat)width;
@end

// The `/` command in one composer: the tag the field starts with, the arrow that runs it, the progress row with
// Cancel, and what the result does to the composer. The request itself is held by the context (one per
// conversation), so going Back or closing the dropdown while it runs loses nothing: the result lands in the
// composer showing that conversation, or in its draft.
@interface SZFriendsComposerCommand : NSObject
- (instancetype)initWithContext:(SZFriendsContext *)context
                 conversationID:(NSString *)conversationID
                       composer:(SZFriendsComposerView *)composer;
@property(nonatomic, readonly) SZFriendsCommandState state;
// The host has an assistant and the composer is enabled; `/` is plain text otherwise.
@property(nonatomic) BOOL enabled;
@property(nonatomic, strong, readonly) SZFriendsFlippedView *tag;
@property(nonatomic, strong, readonly) SZFriendsButton *runButton;
@property(nonatomic, strong, readonly) SZFriendsFlippedView *progressRow;
@property(nonatomic, strong, readonly) NSTextField *progressLabel;
@property(nonatomic, strong, readonly) SZFriendsButton *cancelButton;
@property(nonatomic, strong, readonly) NSTextField *noteLabel; // the host's note with a draft
// The host's commandNote under the field, beside the arrow, only while a command is being written.
@property(nonatomic, strong, readonly) NSTextField *commandNoteLabel;
@property(nonatomic, strong, readonly) SZFriendsProposalView *proposalView; // above everything; hidden without one
@property(nonatomic, readonly) NSString *placeholder; // the host's, while the field holds a command
- (void)setSendLabel:(NSString *)label;               // the composer's, which the proposal's Send uses
- (CGFloat)tagWidth;
- (BOOL)begin;     // `/` in an empty field: Editing; NO when unavailable
- (void)leave;     // Escape: back to a message, keeping what was typed as "/<text>"
- (void)deleteTag; // Delete at the start: back to a message, the `/` gone and the rest kept
- (void)run;       // Return or the arrow while Editing
- (void)cancel;    // Cancel while Running: back to Editing with the command kept
- (void)clearNote;
// A new composer: a saved command opens the field again, a request still running shows its progress, and a
// proposal still waiting shows its card.
- (void)restoreCommand:(NSString *)command;
- (void)adoptRunningRequest;
- (void)sendProposal; // the card's Send
- (void)editProposal; // the card's Edit
@end

NS_ASSUME_NONNULL_END
