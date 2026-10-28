// Light, Dark or Follow system for the reader's windows (SPDFMacAppearanceMode.h).

#import "SPDFMacAppearanceMode.h"
#import <Cocoa/Cocoa.h>

static NSString* AppearanceFile(void) {
    NSString* root = NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ShenzhenPDF"];
    return [root stringByAppendingPathComponent:@"appearance.yaml"];
}
// To the reader's other windows sharing this state, and no other copy of the app.
static NSString* ModeChanged(void) {
    return [@"ShenzhenPDFAppearanceModeChanged:" stringByAppendingString:AppearanceFile()];
}
static NSString* Valid(id mode) {
    return [mode isKindOfClass:NSString.class] && [@[ @"system", @"light", @"dark" ] containsObject:mode] ? mode : nil;
}
static NSString* gMode;
NSString* spdf_appearance_mode(void) {
    if (gMode) return gMode;
    NSString* text = [NSString stringWithContentsOfFile:AppearanceFile() encoding:NSUTF8StringEncoding error:nil];
    for (NSString* line in [text componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"appearanceMode:"])
            gMode = Valid([[line substringFromIndex:15]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    return gMode = gMode ?: @"system";
}
static void Apply(NSString* mode) {
    gMode = mode;
    NSAppearanceName name = [mode isEqualToString:@"light"] ? NSAppearanceNameAqua
                          : [mode isEqualToString:@"dark"]  ? NSAppearanceNameDarkAqua : nil;
    NSApp.appearance = name ? [NSAppearance appearanceNamed:name] : nil;
}
BOOL spdf_appearance_mode_set(NSString* mode) {
    if (!Valid(mode)) return NO;
    NSString* old = [NSString stringWithContentsOfFile:AppearanceFile() encoding:NSUTF8StringEncoding error:nil];
    NSMutableString* text = [NSMutableString string];
    for (NSString* line in [old componentsSeparatedByString:@"\n"])
        if (line.length && ![line hasPrefix:@"appearanceMode:"]) [text appendFormat:@"%@\n", line];
    if (![mode isEqualToString:@"system"]) [text appendFormat:@"appearanceMode: %@\n", mode];
    [NSFileManager.defaultManager createDirectoryAtPath:AppearanceFile().stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL saved = [text writeToFile:AppearanceFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Apply(mode);
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:ModeChanged() object:mode userInfo:nil
                                                     deliverImmediately:YES];
    return saved;
}

// Applied as AppKit finishes launching, before the reader builds its first window.
@interface SPDFMacAppearanceModeLaunch : NSObject
@end
@implementation SPDFMacAppearanceModeLaunch
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillFinishLaunchingNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification* note) {
        (void)note;
        if (![spdf_appearance_mode() isEqualToString:@"system"]) Apply(spdf_appearance_mode());
        // Another window of the reader chose a mode in Settings.
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:ModeChanged() object:nil
                                                                    queue:NSOperationQueue.mainQueue
                                                               usingBlock:^(NSNotification* change) {
            if (Valid(change.object) && ![change.object isEqualToString:gMode]) Apply(change.object);
        }];
    }];
}
@end
