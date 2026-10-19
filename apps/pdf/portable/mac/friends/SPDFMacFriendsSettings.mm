#import "SPDFMacFriendsSettings.h"

NSString* const SPDFMacFriendsSettingsKey = @"friends";
NSString* const SPDFMacFriendsSettingsEnabledKey = @"enabled";
NSString* const SPDFMacFriendsSettingsIntroducedKey = @"settingsIntroduced";
NSString* const SPDFMacFriendsSettingsDidChangeNotification = @"ShenzhenPDFFriendsSettingsChanged";
const NSInteger SPDFMacFriendsSettingsIntroductionRevision = 1;

static NSDictionary* FriendsEntry(NSDictionary* settings) {
    id entry = [settings isKindOfClass:NSDictionary.class] ? settings[SPDFMacFriendsSettingsKey] : nil;
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}

// YAML booleans arrive as NSNumber via NSJSONSerialization. A hand-edited "no" or "0" is a string or a number that
// is not a JSON boolean; treating only a real boolean false as off keeps a typo from silently disabling reception.
static BOOL IsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

BOOL SPDFMacFriendsEnabledInSettings(NSDictionary* settings) {
    id value = FriendsEntry(settings)[SPDFMacFriendsSettingsEnabledKey];
    return IsJSONBoolean(value) ? [value boolValue] : YES;
}

NSInteger SPDFMacFriendsIntroducedRevisionInSettings(NSDictionary* settings) {
    id value = FriendsEntry(settings)[SPDFMacFriendsSettingsIntroducedKey];
    return [value isKindOfClass:NSNumber.class] && !IsJSONBoolean(value) ? MAX(0, [value integerValue]) : 0;
}

@implementation SPDFMacFriendsSettingsState {
    NSMutableDictionary* _entry;
    BOOL _loaded;
}

+ (instancetype)sharedState {
    static SPDFMacFriendsSettingsState* state;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ state = [SPDFMacFriendsSettingsState new]; });
    return state;
}

- (void)loadFromSettings:(NSDictionary*)settings {
    NSMutableDictionary* entry = [FriendsEntry(settings) mutableCopy] ?: [NSMutableDictionary dictionary];
    // Normalize the two keys this build owns, so a malformed value is rewritten as what it was read as.
    entry[SPDFMacFriendsSettingsEnabledKey] = @(SPDFMacFriendsEnabledInSettings(settings));
    entry[SPDFMacFriendsSettingsIntroducedKey] = @(SPDFMacFriendsIntroducedRevisionInSettings(settings));
    @synchronized(self) { _entry = entry; _loaded = YES; }
}

- (BOOL)isLoaded { @synchronized(self) { return _loaded; } }

- (BOOL)isEnabled {
    @synchronized(self) { return !_loaded || [_entry[SPDFMacFriendsSettingsEnabledKey] boolValue]; }
}

- (NSInteger)introducedRevision {
    @synchronized(self) { return [_entry[SPDFMacFriendsSettingsIntroducedKey] integerValue]; }
}

- (void)setEnabled:(BOOL)enabled {
    @synchronized(self) {
        if (!_entry) _entry = [NSMutableDictionary dictionary];
        _entry[SPDFMacFriendsSettingsEnabledKey] = @(enabled);
        _loaded = YES;
    }
}

- (void)setIntroducedRevision:(NSInteger)revision {
    @synchronized(self) {
        if (!_entry) _entry = [NSMutableDictionary dictionaryWithObject:@YES forKey:SPDFMacFriendsSettingsEnabledKey];
        _entry[SPDFMacFriendsSettingsIntroducedKey] = @(MAX(0, revision));
        _loaded = YES;
    }
}

- (NSDictionary*)settingsByAddingFriends:(NSDictionary*)settings {
    NSDictionary* entry;
    @synchronized(self) { entry = _loaded ? [_entry copy] : nil; }
    if (!entry || ![settings isKindOfClass:NSDictionary.class]) return settings;
    NSMutableDictionary* merged = [settings mutableCopy];
    merged[SPDFMacFriendsSettingsKey] = entry;
    return merged;
}

@end

NSDictionary* SPDFMacFriendsSettingsForSaving(NSDictionary* settings) {
    return [SPDFMacFriendsSettingsState.sharedState settingsByAddingFriends:settings];
}
