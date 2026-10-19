// The `@` and `#` pickers and the scope note in AI chat's composer (brief § AI boundaries; ai-agent-capabilities.md
// § 1).
//
// Typing "@" at the start of a word opens a small searchable picker of All Friends chats and each friend; choosing
// a friend replaces the "@" with a chip. Choosing All Friends chats first asks for how long: "This request" makes a
// chip like a friend's, "1 hour" and "Until tomorrow" start the AI chat's time grant (SPDFMacFriendsChatGrant.h),
// shown by the bar above the chat rather than by a chip, and the "@" goes. Typing "#" opens the same picker over
// the documents the host offers (open and Collection documents); choosing one inserts a file chip, one of the files
// a send in that message may carry. While
// the composer holds a chip, a note inside the input box says what the chosen chats are used for and that they go
// to OpenRouter for this message. Nothing here sends or opens a scope: the chips are read when the message is sent
// (SPDFMacFriendsChatRequestScoper). The pickers only appear while Friends can open chat scopes, so a reader with
// Friends off, or a helper without assistant scopes, sees no `@` or `#` behaviour at all.

#import <AppKit/AppKit.h>
#import "SPDFMacAIRequestContext.h"
#import "SPDFMacFriendsChatGrant.h"

NS_ASSUME_NONNULL_BEGIN

// Each choice is {"id", "name"}; a `#` choice also carries "file", its SPDFMacAIRequestChip.
typedef void (^SPDFMacFriendsChoicesDelivery)(NSArray<NSDictionary<NSString*, id>*>* choices);

// The picker's content view; "szfriends." keeps it from the assistant's app_controls (SPDFMacAIAppControls.h), so
// only the person can choose what it reads.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsScopePickerIdentifier; // "szfriends.scopePicker"

@interface SPDFMacFriendsComposerScope : NSObject
// `choices` asks Friends for the picker's rows (SPDFMacFriendsScopeChoices) and delivers them on the main thread.
- (instancetype)initWithComposer:(NSTextView*)composer
                         choices:(void (^)(SPDFMacFriendsChoicesDelivery deliver))choices NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic) BOOL available;
// The `#` picker's rows: documents the person may attach, each choice carrying its file chip. nil: no `#` picker.
@property(nonatomic, copy, nullable) void (^fileChoices)(SPDFMacFriendsChoicesDelivery deliver);
// The `#` picker's search placeholder, which names what the host offers.
@property(nonatomic, copy) NSString* filePlaceholder;
@property(nonatomic, readonly) NSTextField* note;     // inside the composer's scroll view; hidden without a chip
@property(nonatomic, readonly, getter=isPickerShown) BOOL pickerShown;
// Presents the picker for the "@" or "#" at `index`. Replaceable so a headless test can observe the request without a
// popover, which needs a window on screen.
@property(nonatomic, copy) void (^presentPicker)(NSUInteger index, NSArray<NSDictionary<NSString*, id>*>* choices);
// Starts the time grant for All Friends chats; YES when it started. nil: All Friends chats is a chip for this
// message only, with no question about how long.
@property(nonatomic, copy, nullable) BOOL (^grantAllChats)(SPDFMacFriendsGrantLength length);
// Asks how long, with SPDFMacFriendsGrantLengthChoices(), in the open picker. Replaceable like presentPicker.
@property(nonatomic, copy) void (^presentLengths)(NSUInteger index, NSArray<NSDictionary<NSString*, id>*>* choices);
// The picker's content for these rows: a search field, or `title` above rows that are not searched.
- (NSView*)pickerViewWithChoices:(NSArray<NSDictionary<NSString*, id>*>*)choices title:(nullable NSString*)title;
// Replaces the "@" or "#" at the pending index (or inserts at the caret) with a chip for `choice`; for All Friends
// chats with grantAllChats set, asks how long instead, and a choice of length grants or makes the chip.
- (void)choose:(NSDictionary<NSString*, id>*)choice;
// Inserts a file chip for each file at the caret: for files dropped on the composer.
- (void)insertFiles:(NSArray<SPDFMacAIRequestChip*>*)files;
- (void)refreshNote;
- (void)uninstall;
@end

NS_ASSUME_NONNULL_END
