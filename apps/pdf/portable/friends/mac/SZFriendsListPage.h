// Shenzhen Friends list page: search, Friends / Nearby tabs, rows, the footer (internal).

#import "mac/SZFriendsRowView.h"

NS_ASSUME_NONNULL_BEGIN

// The name friends see, typed in: a field with Save beside it, and under them why a name was refused. The name
// prompt's card and the footer's rename both use it, so both save the same way: Save or Return sends set_name with
// the trimmed name; nothing typed (or only spaces) shows welcome.strings name_empty instead; the helper's refusal
// (too long, a line break) shows its message; Escape drops what was typed. While the helper has not answered, the
// field rests and a spinner turns where the text is.
// How long "Saved — friends now see …" stays where the name was typed before the place goes back to normal.
static const NSTimeInterval SZFriendsNameSavedSeconds = 2.5;

@interface SZFriendsNameEditor : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context font:(NSFont *)font;
@property(nonatomic, strong, readonly) NSTextField *field;
@property(nonatomic, strong, readonly) SZFriendsButton *saveButton; // hidden when the helper sends no `save` string
// Cancel beside Save (welcome.strings cancel), for a rename that can be left: it calls onCancel. Off by default.
@property(nonatomic) BOOL showsCancel;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *cancelButton;
@property(nonatomic, strong, readonly) NSTextField *messageLabel;
// The name already saved; Save waits for a different one.
@property(nonatomic, copy, nullable) NSString *currentName;
@property(nonatomic, readonly, getter=isSaving) BOOL saving;
@property(nonatomic, copy, nullable) void (^onSaved)(NSString *name); // after the helper said yes
// Escape while the field holds something other than currentName (or a refusal shows). Unset: the field empties.
// With nothing changed, Escape goes on to the dropdown (which closes an open rename, or itself).
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@property(nonatomic, copy, nullable) void (^onEndEditing)(void);
@property(nonatomic, copy, nullable) void (^onLayoutChange)(void); // a message appeared or went
@property(nonatomic, readonly) BOOL hasTyping;
- (void)save;
// Drops what was typed (onCancel); NO when nothing differs from currentName (Escape then goes on to the dropdown).
- (BOOL)cancelTyping;
- (void)reset;
- (void)reloadStrings;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

// The footer under both tabs: the name friends see (click to edit in place), the ID with Copy, and Add by ID.
// Renaming puts the field with Save and Cancel where the name was: Return or Save saves, Escape, Cancel or a click
// anywhere else in the list leaves it. Once saved, the name shows with a check for a moment (name_saved).
@interface SZFriendsFooterView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyFooter:(nullable NSDictionary *)footer; // PROTOCOL.md footer
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, strong, readonly) SZFriendsButton *nameButton;
@property(nonatomic, strong, readonly) SZFriendsButton *cpyButton; // "copy" is reserved for NSCopying
@property(nonatomic, strong, readonly) SZFriendsButton *addButton;
@property(nonatomic, readonly, getter=isEditingName) BOOL editingName;
// The rename, while editingName: the field, Save and a refusal, in place of the name and Add by ID.
@property(nonatomic, strong, readonly, nullable) SZFriendsNameEditor *nameEditor;
- (void)beginEditingName;
- (BOOL)cancelEditingName; // YES when an edit was open
@property(nonatomic, readonly) BOOL showingNameSaved; // the name with its check, just after a rename
@property(nonatomic, copy, nullable) void (^onAddByID)(void);
// NO on a computer removed from the person's profile, which can add nobody (PROTOCOL.md § Devices); default YES.
@property(nonatomic) BOOL offersAdding;
@end

// The Nearby tab's content: visibility card, the one alert or quiet note, people as each method reports them.
@interface SZFriendsNearbyPane : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyNearby:(NSDictionary *)data;
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, copy, readonly) NSArray<SZFriendsRowView *> *personRows;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *visibilityButton;
@property(nonatomic, copy, nullable) void (^onOpenConversation)(NSString *conversationID);
@end

// A card or a quiet line: the ID-changed banner, the name prompt, "Send 2 files to…", the drop hint, Nearby's
// visibility card, alert and note. Text column (title, body, field, note, button) with an optional trailing
// column (the countdown over Stop, or a short action like the banner's OK) and an optional leading icon.
@interface SZFriendsNoticeView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (CGFloat)heightForWidth:(CGFloat)width;
@property(nonatomic, strong, readonly) NSTextField *titleLabel;
@property(nonatomic, strong, readonly) NSTextField *bodyLabel;
@property(nonatomic, strong, readonly) NSTextField *noteLabel;
@property(nonatomic, strong, nullable) SZFriendsNameEditor *nameEditor; // the name prompt's field and Save
@property(nonatomic, strong, nullable) SZFriendsButton *button;
@property(nonatomic, strong, nullable) SZFriendsButton *secondaryButton; // a link under the text ("Copy link instead")
@property(nonatomic, strong, nullable) NSTextField *bigLabel;  // the visibility countdown
@property(nonatomic) BOOL buttonTrailing;
@property(nonatomic) BOOL buttonFullWidth;
@property(nonatomic) BOOL buttonFirst; // the button above the text instead of under it
@property(nonatomic) CGFloat padding;
@property(nonatomic, copy, nullable) SZFriendsIconDrawer iconDrawer;
@property(nonatomic, strong, nullable) NSColor *iconColor;
// Replaces the button with one for a PROTOCOL.md action (nil or unknown: no button).
- (void)setAction:(nullable NSDictionary *)action onPress:(nullable void (^)(NSDictionary *action))onPress;
@end

@class SZFriendsListDevicesView;

@interface SZFriendsListPage : SZFriendsPage
// The small tag beside the title that says Friends is a beta (welcome.strings beta); nil while it is not shown.
@property(nonatomic, strong, readonly, nullable) NSView *betaTagView;
@property(nonatomic, strong, readonly) NSSearchField *searchField;
@property(nonatomic, strong, readonly) SZFriendsButton *friendsTab;
@property(nonatomic, strong, readonly) SZFriendsButton *nearbyTab;
@property(nonatomic, readonly) BOOL showingNearby;
- (void)showNearby:(BOOL)nearby;
@property(nonatomic, strong, readonly) SZFriendsFooterView *footer;
@property(nonatomic, strong, readonly) SZFriendsNearbyPane *nearbyPane;
@property(nonatomic, copy, readonly) NSArray<SZFriendsRowView *> *rows;
@property(nonatomic, strong, readonly) NSScrollView *scrollView;
- (void)applyNearbySnapshot:(NSDictionary *)data;
// While files are dragged in through the Friends button: the hint, or why they cannot be sent, above the rows.
- (void)setDropHint:(nullable NSString *)hint;
// `refusing`: the hint is that refusal (drop_folders_refused, drop_not_a_file), so the rows that take files show
// only the refuse style rather than repeating it.
- (void)setDropHint:(nullable NSString *)hint refusing:(BOOL)refusing;
// "Send 2 files to…" (the send picker) above the rows, with Cancel; nil hides it. The tooltip lists every file.
- (void)setSendPickerTitle:(nullable NSString *)title;
- (void)setSendPickerTitle:(nullable NSString *)title toolTip:(nullable NSString *)toolTip;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *sendPickerCancelButton;
// A second way out of "Send 1 file to…", under its title: the host's "Copy link instead" (SZFriendsHost.h). It goes
// with the picker.
- (void)setSendPickerLinkButton:(nullable SZFriendsButton *)button;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *sendPickerLinkButton;
// The name prompt's field and the banner's action, for tests and keyboard focus.
@property(nonatomic, strong, readonly, nullable) NSTextField *namePromptField;
@property(nonatomic, strong, readonly, nullable) SZFriendsNameEditor *namePromptEditor; // nil while it says "Saved"
// The name card saying the name was saved (welcome.strings name_saved), for SZFriendsNameSavedSeconds before it goes.
@property(nonatomic, readonly) BOOL showingNameSaved;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *bannerButton;
// Several computers (SZFriendsDevices.h): the removed notice and join rows, and "Use my existing profile…" in the
// name prompt or its own card (nil while the list has no `join`).
@property(nonatomic, strong, readonly) SZFriendsListDevicesView *devicesView;
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *joinButton;
@end

NS_ASSUME_NONNULL_END
