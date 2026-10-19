// The Friends section of ShenzhenPDF's Settings: the reader's own checkbox and disclosure, then the views' section.
//
// "Enable Shenzhen Friends" and the disclosure are the host's (PROTOCOL.md § Views, settings): they show while
// Friends is off and no helper runs to supply strings. While Friends is on, the views' SZFriendsSettingsSection
// (name, ID, received files, automatic acceptance, Delete history, Reset Friends) follows them. The pane reaches the
// reader through SPDFMacFriendsSettingsPaneSource, registered once per process, because the Settings window is
// built by SPDFMacUnifiedSettingsController, which knows nothing about Friends.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Written for the person deciding whether to keep Friends on, and true for M1 (brief § Product contract, Disclosure).
FOUNDATION_EXPORT NSString* const SPDFMacFriendsEnableTitle;      // "Enable Shenzhen Friends"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsDisclosureText;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsHeading;  // "Shenzhen Friends"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsSubtitle;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsSectionKey; // "friends": the Settings section identifier
// Posted (locally) when Friends was turned on or off or attached, so an open pane shows the new state.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsPaneRefreshNotification;

@protocol SPDFMacFriendsSettingsPaneSource <NSObject>
@property(nonatomic, readonly) BOOL friendsEnabled;
// The person ticked or unticked the checkbox: save settings.yaml, attach or detach, tell other windows.
- (void)friendsSettingsSetEnabled:(BOOL)enabled;
// The views' section while Friends is on and attached; nil otherwise.
- (nullable NSView*)friendsSettingsSectionViewWillAppear;
- (void)friendsSettingsSectionDidDisappear;
@end

void SPDFMacFriendsSetSettingsPaneSource(id<SPDFMacFriendsSettingsPaneSource> _Nullable source);
id<SPDFMacFriendsSettingsPaneSource> _Nullable SPDFMacFriendsSettingsPaneSourceForProcess(void);

@interface SPDFMacFriendsSettingsPane : NSView
- (instancetype)initWithSource:(nullable id<SPDFMacFriendsSettingsPaneSource>)source NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;
@property(nonatomic, readonly) NSButton* enableCheckbox;
@property(nonatomic, readonly) NSTextField* disclosure;
// Holds the views' section while Friends is on; empty while off.
@property(nonatomic, readonly) NSView* sectionContainer;
// Re-reads the source: after the checkbox, and when another window changed the setting.
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
