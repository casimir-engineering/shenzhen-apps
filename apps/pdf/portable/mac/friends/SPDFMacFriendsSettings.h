// ShenzhenPDF's own Friends setting: the `friends` entry in settings.yaml.
//
// settings.yaml holds only whether this app shows Friends (brief § Storage), so a disabled launch costs nothing
// beyond the settings read the reader already makes: the launch hook hands this class the dictionary
// loadPersistentState parsed, and never opens a file itself.
//
// The coordinator rewrites settings.yaml from a literal dictionary on every save, which would drop a key it does
// not know. Its save therefore passes through SPDFMacFriendsSettingsForSaving(), which carries this process's
// `friends` entry across. Windows are processes, so a change made in one window is posted as a distributed
// notification and every other window reloads the file before its next save can write a stale value.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsKey;             // "friends"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsEnabledKey;      // "enabled"
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsIntroducedKey;   // "settingsIntroduced"
// Posted (distributed, no user info) after a window saved a Friends change; observers reread settings.yaml.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsSettingsDidChangeNotification;
// Raise when a release changes what the Friends section of Settings must tell every reader once.
FOUNDATION_EXPORT const NSInteger SPDFMacFriendsSettingsIntroductionRevision;

// friends.enabled. Friends is on by default (brief § Decisions), so a missing file, a missing key and any value
// that is not a boolean all mean YES: only an explicit `false` written by Settings turns it off.
BOOL SPDFMacFriendsEnabledInSettings(NSDictionary* _Nullable settings);
NSInteger SPDFMacFriendsIntroducedRevisionInSettings(NSDictionary* _Nullable settings);

@interface SPDFMacFriendsSettingsState : NSObject
// One per process: settings.yaml is per process too (the coordinator owns one file for all its windows).
+ (instancetype)sharedState;

// The settings.yaml dictionary as parsed, at launch and again after another window posted a change. Keys inside
// `friends` that this build does not know are kept, so an older build never erases a newer one's choices.
- (void)loadFromSettings:(nullable NSDictionary*)settings;
@property(nonatomic, readonly, getter=isLoaded) BOOL loaded;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly) NSInteger introducedRevision;
- (void)setEnabled:(BOOL)enabled;
- (void)setIntroducedRevision:(NSInteger)revision;

// `settings` with this process's `friends` entry set. Before -loadFromSettings: it returns `settings` unchanged,
// since an unloaded state has nothing truthful to write.
- (NSDictionary*)settingsByAddingFriends:(NSDictionary*)settings;
@end

// The coordinator's settings.yaml save: [self writeStateObject:SPDFMacFriendsSettingsForSaving(@{...}) ...].
NSDictionary* SPDFMacFriendsSettingsForSaving(NSDictionary* settings);

NS_ASSUME_NONNULL_END
