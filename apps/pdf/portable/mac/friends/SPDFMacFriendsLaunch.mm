#import "SPDFMacFriendsLaunch.h"
#import "SPDFMacFriendsSettings.h"

NSString* const SPDFMacFriendsHelperBundleName = @"Shenzhen Friends.app";
NSString* const SPDFMacFriendsHelperExecutableName = @"Shenzhen Friends";

@implementation SPDFMacFriendsLaunchEnvironment

- (instancetype)initWithSpawn:(SPDFMacFriendsSpawnFunction)spawn {
    if (!(self = [super init])) return nil;
    _spawn = [spawn copy];
    _dispatchBackground = ^(dispatch_block_t block) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), block);
    };
    return self;
}

@end

BOOL SPDFMacFriendsPrepareAtLaunch(BOOL enabled, SPDFMacFriendsLaunchEnvironment* environment) {
    if (!enabled || !environment.spawn || !environment.dispatchBackground) return NO;
    dispatch_block_t prepareSigning = environment.prepareSigning;
    environment.dispatchBackground(^{
        @autoreleasepool {
            // Reading the app's own signature costs a few milliseconds, so it happens here, off the launch path,
            // and the attach after first paint finds the policy already set.
            if (prepareSigning) prepareSigning();
        }
    });
    return YES;
}

BOOL SPDFMacFriendsSpawnBeforeAttach(NSString* (^helperPath)(void), SPDFMacFriendsLaunchEnvironment* environment) {
    if (!environment.spawn || !environment.dispatchBackground) return NO;
    SPDFMacFriendsSpawnFunction spawn = environment.spawn;
    dispatch_block_t prepareSigning = environment.prepareSigning;
    NSString* (^path)(void) = [helperPath copy];
    environment.dispatchBackground(^{
        @autoreleasepool {
            if (prepareSigning) prepareSigning(); // set at launch already; waits for it if still being read
            NSString* executable = path ? path() : nil;
            // Nothing embedded (a development build): the link's status line says Friends is unavailable;
            // spawning a missing path would only log an error.
            if (!executable.length) return;
            pid_t pid = 0;
            (void)spawn(executable, nil, &pid);
        }
    });
    return YES;
}

NSString* SPDFMacFriendsHelperExecutablePath(NSBundle* bundle) {
    NSString* helper = [[bundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers"]
        stringByAppendingPathComponent:SPDFMacFriendsHelperBundleName];
    NSString* executable = [helper stringByAppendingPathComponent:
        [@"Contents/MacOS" stringByAppendingPathComponent:SPDFMacFriendsHelperExecutableName]];
    return [NSFileManager.defaultManager isExecutableFileAtPath:executable] ? executable : nil;
}


@implementation SPDFMacFriendsLifecycle {
    SPDFMacFriendsSettingsState* _settings;
    SPDFMacFriendsLaunchEnvironment* _environment;
    NSString* (^_helperPath)(void);
    void (^_attach)(void);
    void (^_detach)(BOOL);
    BOOL _painted;
    BOOL _attached;
    BOOL _spawnDue; // enabled at launch: the first attach also runs the environment's spawn
}

- (instancetype)initWithSettings:(SPDFMacFriendsSettingsState*)settings
                     environment:(SPDFMacFriendsLaunchEnvironment*)environment
                      helperPath:(NSString* (^)(void))helperPath
                          attach:(void (^)(void))attach
                          detach:(void (^)(BOOL))detach {
    if (!(self = [super init])) return nil;
    _settings = settings;
    _environment = environment;
    _helperPath = [helperPath copy];
    _attach = [attach copy];
    _detach = [detach copy];
    return self;
}

- (BOOL)isAttached { return _attached; }

- (void)launchWithSettings:(NSDictionary*)settings {
    [_settings loadFromSettings:settings];
    _spawnDue = SPDFMacFriendsPrepareAtLaunch(_settings.enabled, _environment);
}

- (void)apply:(BOOL)disabling {
    BOOL wanted = _painted && _settings.enabled;
    if (wanted && !_attached) {
        // The link connects as it attaches; a launch hop still reading the signature finishes first.
        if (_environment.prepareSigning) _environment.prepareSigning();
        // After the first frame, never beside it: a helper starting up while the window is built costs the
        // reader's main thread time on a busy Mac. The link's first attempt spawns it when nothing listens.
        if (_spawnDue) _spawnDue = !SPDFMacFriendsSpawnBeforeAttach(_helperPath, _environment);
        _attached = YES;
        if (_attach) _attach();
    }
    else if (!wanted && _attached) { _attached = NO; if (_detach) _detach(disabling); }
}

- (void)firstPaintDidHappen {
    _painted = YES;
    [self apply:NO];
}

- (void)setEnabled:(BOOL)enabled {
    [_settings setEnabled:enabled];
    [self apply:!enabled];
}

- (void)settingsDidChange:(NSDictionary*)settings {
    [_settings loadFromSettings:settings];
    // Another window turned Friends off and already sent `disable`; this window only disconnects, and the helper
    // exits once no window with Friends on remains connected.
    [self apply:NO];
}

@end
