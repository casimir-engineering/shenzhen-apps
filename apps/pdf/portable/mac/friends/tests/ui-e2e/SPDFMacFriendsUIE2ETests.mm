// friends-ui-e2e's runner (SPDFMacFriendsUIE2E.h).
//
// Usage: SPDFMacFriendsUIE2ETests <e2e helper> <animal manifest> <screenshots folder>
// FRIENDS_UI_E2E_VARIANTS=light-normal,dark-narrow runs only those looks; FRIENDS_UI_E2E_FLOWS=solo,permission,pair,found
// only those groups, while working on them. The screenshots folder gets <variant>/<flow>/<NN>-<step>.png and
// flows.tsv, the result of every flow in every look.

#import "SPDFMacFriendsUIE2E.h"

#import "mac/SZFriendsPage.h"

static UIVariant* UIMakeVariant(NSString* name, NSAppearanceName appearance, CGFloat width, CGFloat height) {
    UIVariant* variant = [UIVariant new];
    variant.name = name;
    variant.appearance = appearance;
    variant.dropdownWidth = width;
    variant.windowHeight = height;
    return variant;
}

static BOOL UIWanted(const char* variable, NSString* name) {
    const char* value = getenv(variable);
    if (!value || !*value) return YES;
    return [[@(value) componentsSeparatedByString:@","] containsObject:name];
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: SPDFMacFriendsUIE2ETests <e2e helper> <animal manifest> <screenshots folder>\n");
            return 2;
        }
        UIHelperExecutable = @(argv[1]);
        UIManifest = @(argv[2]);
        UIShotsRoot = @(argv[3]);
        if (![NSFileManager.defaultManager isExecutableFileAtPath:UIHelperExecutable]) {
            fprintf(stderr, "no helper at %s\n", argv[1]);
            return 2;
        }
        [NSFileManager.defaultManager removeItemAtPath:UIShotsRoot error:nil];
        [NSFileManager.defaultManager createDirectoryAtPath:UIShotsRoot withIntermediateDirectories:YES attributes:nil
                                                      error:nil];
        // Short and private, under the per-user temp folder: every helper's home, state and socket of this run.
        char pattern[1024];
        strlcpy(pattern, [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfui.XXXXXX"].fileSystemRepresentation,
                sizeof pattern);
        if (!mkdtemp(pattern)) return 2;
        UIRoot = @(pattern);
        // Nothing of the reader's or Friends' real state is read or written: the link and the reader's state follow
        // these, and no Keychain item is ever touched (the helpers use the file key store).
        setenv("SZFRIENDS_KEY_STORE", "file", 1);
        setenv("SPDF_STATE_DIR", UIRoot.fileSystemRepresentation, 1);
        [SZFriendsAvatarView setAnimalManifestPath:UIManifest];

        [NSApplication sharedApplication];
        UIKeepWindowsOffscreen();
        // An accessory app: no Dock icon, no menu bar, and never activated, so the person's own apps keep focus.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        UIFlowResults = [NSMutableArray array];
        SZFE2EWorld* world = [[SZFE2EWorld alloc] initWithExecutable:UIHelperExecutable manifest:UIManifest root:UIRoot];
        NSArray<UIVariant*>* variants = @[
            UIMakeVariant(@"light-normal", NSAppearanceNameAqua, 400, 780),
            UIMakeVariant(@"dark-normal", NSAppearanceNameDarkAqua, 400, 780),
            UIMakeVariant(@"light-narrow", NSAppearanceNameAqua, 320, 540),
            UIMakeVariant(@"dark-narrow", NSAppearanceNameDarkAqua, 320, 540),
        ];
        struct {
            const char* name;
            UIFlow run;
        } groups[] = {{"solo", UIFlowSolo}, {"permission", UIFlowPermission}, {"pair", UIFlowTwoPeople}, {"found", UIFlowFound}};
        NSDate* started = NSDate.date;
        for (UIVariant* variant in variants) {
            if (!UIWanted("FRIENDS_UI_E2E_VARIANTS", variant.name)) continue;
            NSApp.appearance = [NSAppearance appearanceNamed:variant.appearance];
            printf("%s\n", variant.name.UTF8String);
            for (auto& group : groups) {
                if (!UIWanted("FRIENDS_UI_E2E_FLOWS", @(group.name))) continue;
                @autoreleasepool {
                    group.run(world, variant);
                }
            }
        }
        NSString* summary = [[UIFlowResults componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        [summary writeToFile:[UIShotsRoot stringByAppendingPathComponent:@"flows.tsv"] atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
        NSUInteger failed = [UIFlowResults filteredArrayUsingPredicate:
                                 [NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'FAIL'"]].count;
        [NSFileManager.defaultManager removeItemAtPath:UIRoot error:nil];
        printf("%lu flows, %lu failed, %d failed checks, %.0f s; screenshots in %s\n",
               (unsigned long)UIFlowResults.count, (unsigned long)failed, UIFailures,
               -started.timeIntervalSinceNow, UIShotsRoot.UTF8String);
        if (failed || UIFailures || !UIFlowResults.count) return 1;
        puts("SPDFMacFriendsUIE2ETests passed");
        return 0;
    }
}
