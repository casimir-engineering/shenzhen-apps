// Settings' Python row as the reader supplies it (SPDFMacAIPythonSettingsSource.h): the real Settings window with
// the real installer in a throwaway folder and a stand-in install script, so nothing is downloaded. Also the hook
// that hands the source to Settings, as source text, since the reader's categories need the whole app to link.
// Included by SPDFMacAIPythonTests.mm.
#pragma once
#import "SPDFMacAIPythonFakes.h"
#import "SPDFMacAIPythonSettingsSource.h"

static NSView* SettingsFind(NSView* view, NSString* identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView* child in view.subviews) {
        NSView* found = SettingsFind(child, identifier);
        if (found) return found;
    }
    return nil;
}
static BOOL SettingsShown(NSView* view) {
    for (NSView* v = view; v; v = v.superview) if (v.hidden) return NO;
    return view != nil;
}
static NSString* SettingsText(NSView* root, NSString* identifier) {
    return [(NSTextField*)SettingsFind(root, identifier) stringValue] ?: @"";
}

// The AI page with the state the reader builds: saved switches plus the source's status, and Install… routed as the
// reader routes it.
static SPDFMacUnifiedSettingsController* SettingsPage(SPDFMacAIPythonSettingsSource* source) {
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:
        [NSURL fileURLWithPath:[gImages stringByAppendingPathComponent:@"settings/ai-settings.yaml"]]];
    SPDFMacUnifiedSettingsController* page =
        [[SPDFMacUnifiedSettingsController alloc] initWithState:SPDFMacAICapabilitiesState(settings, source)];
    __weak SPDFMacUnifiedSettingsController* weakPage = page;
    page.actionHandler = ^(NSString* action) { SPDFMacAICapabilitiesPerformAction(action, weakPage, source); };
    [page selectSection:@"ai"];
    [page.window.contentView layoutSubtreeIfNeeded];
    return page;
}

static void CheckSettingsSource(NSString* scratch) {
    NSString* directory = [scratch stringByAppendingPathComponent:@"settings-python/assistant-python"];
    NSString* fake = [NSString stringWithFormat:@"echo '## Downloading numpy, pandas and matplotlib'\nsleep 0.3\n"
                                                 "mkdir -p '%@/bin' && printf '#!/bin/sh\\n' > '%@/bin/python3' && "
                                                 "chmod +x '%@/bin/python3'\necho '## Installed'\n"
                                                 "touch '%@/.shenzhenpdf-ready'\n",
                                                directory, directory, directory, directory];
    SPDFMacAIPythonInstaller* installer = [[SPDFMacAIPythonInstaller alloc] initWithDirectory:directory script:fake];
    SPDFMacAIPythonSettingsSource* source = [[SPDFMacAIPythonSettingsSource alloc] initWithEnvironment:installer
                                                                                         helperPresent:YES];
    __block NSUInteger asked = 0;
    __block BOOL answer = NO;
    source.confirmation = ^(NSWindow* window, void (^reply)(BOOL)) { (void)window; asked++; reply(answer); };
    NSDictionary* status = source.pythonSandboxSettingsStatus;
    CHECK([status[SPDFMacAIPythonStatusKey] isEqual:SPDFMacAIPythonStatusNotInstalled] &&
          [status[SPDFMacAIPythonLocationKey] isEqual:directory] &&
          [status[SPDFMacAIPythonDownloadKey] isEqual:SPDFMacAIPythonInstallSummary()],
          "before installing, Settings hears where Python would live and the chat card's download sentence");

    SPDFMacUnifiedSettingsController* page = SettingsPage(source);
    NSView* root = page.window.contentView;
    NSButton* use = (NSButton*)SettingsFind(root, SPDFMacAIPythonEnabledKey);
    NSButton* install = (NSButton*)SettingsFind(root, SPDFMacAIPythonInstallAction);
    CHECK(SettingsShown(SettingsFind(root, @"aiPythonRow")) && SettingsShown(use) &&
          [use.title isEqual:@"Let the assistant run Python"] && SettingsShown(install) &&
          [SettingsText(root, @"aiPythonStatusLabel") isEqual:@"Not installed"],
          "the AI page now shows the Python row: the switch, Not installed and Install…");
    [install performClick:nil];
    CHECK(asked == 1 && !installer.installing && [SettingsText(root, @"aiPythonStatusLabel") isEqual:@"Not installed"],
          "Install… asks first; Cancel downloads nothing");
    answer = YES;
    [install performClick:nil];
    CHECK(asked == 2 && installer.installing && [SettingsText(root, @"aiPythonStatusLabel") isEqual:@"Installing…"] &&
          !SettingsShown(install), "Install confirmed: the row says Installing… with nothing to press");
    SandboxWait(^BOOL { return [SettingsText(root, @"aiPythonStatusLabel") hasPrefix:@"Installed in "]; });
    CHECK([SettingsText(root, @"aiPythonStatusLabel") isEqual:
              [@"Installed in " stringByAppendingString:directory.stringByAbbreviatingWithTildeInPath]] &&
          installer.installed && SettingsShown(use), "when it finishes, the row says where Python is installed");
    [install performClick:nil];
    CHECK(asked == 2, "installed already: Install… is hidden, and asking again would not reinstall");
    SPDFMacUnifiedSettingsController* reopened = SettingsPage(source);
    CHECK([SettingsText(reopened.window.contentView, @"aiPythonStatusLabel") hasPrefix:@"Installed in "],
          "Settings opened again reads the installation from the folder");

    SPDFMacAIPythonInstaller* failing = [[SPDFMacAIPythonInstaller alloc] initWithDirectory:
        [scratch stringByAppendingPathComponent:@"settings-failing/assistant-python"]
        script:@"echo '!! Could not download numpy, pandas and matplotlib. Check the internet connection, then try "
               @"again.'\nexit 1\n"];
    SPDFMacAIPythonSettingsSource* stopped = [[SPDFMacAIPythonSettingsSource alloc] initWithEnvironment:failing
                                                                                          helperPresent:YES];
    stopped.confirmation = ^(NSWindow* window, void (^reply)(BOOL)) { (void)window; reply(YES); };
    page = SettingsPage(stopped);
    root = page.window.contentView;
    [(NSButton*)SettingsFind(root, SPDFMacAIPythonInstallAction) performClick:nil];
    SandboxWait(^BOOL { return !failing.installing; });
    SandboxSpin(0.1);
    NSString* detail = SettingsText(root, @"aiPythonStatusDetail");
    CHECK([detail hasPrefix:@"Could not download numpy"] && [detail containsString:SPDFMacAIPythonInstallSummary()] &&
          SettingsShown(SettingsFind(root, SPDFMacAIPythonInstallAction)),
          "a stopped install says why, and offers Install… again");

    SPDFMacAIPythonSettingsSource* incomplete = [[SPDFMacAIPythonSettingsSource alloc] initWithEnvironment:installer
                                                                                             helperPresent:NO];
    root = SettingsPage(incomplete).window.contentView;
    CHECK([SettingsText(root, @"aiPythonStatusLabel") isEqual:@"Not available"] &&
          [SettingsText(root, @"aiPythonStatusDetail") containsString:@"Installing ShenzhenPDF again"] &&
          !((NSButton*)SettingsFind(root, SPDFMacAIPythonEnabledKey)).enabled,
          "a copy of the app without the Python helper says so, and the switch cannot be changed");
    for (NSString* path in @[ directory.stringByDeletingLastPathComponent,
                              failing.directory.stringByDeletingLastPathComponent ])
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

// After CheckFailures, whose scripted run reported that the sandbox could not be applied.
static void CheckSettingsAfterRefusal(NSString* scratch) {
    FakeEnvironment* environment = [FakeEnvironment new];
    environment.interpreterPath = [scratch stringByAppendingPathComponent:@"refused/bin/python3"];
    SPDFMacAIPythonSettingsSource* source = [[SPDFMacAIPythonSettingsSource alloc] initWithEnvironment:environment
                                                                                         helperPresent:YES];
    NSView* root = SettingsPage(source).window.contentView;
    CHECK(SPDFMacAIPythonSandboxRefused() && [SettingsText(root, @"aiPythonStatusLabel") isEqual:@"Not available"] &&
          [SettingsText(root, @"aiPythonStatusDetail") hasPrefix:@"This Mac can’t keep Python cut off"],
          "once this Mac refused the sandbox, Settings says the switch cannot take effect here");
}

// A card still offering Install after Python was installed from Settings must not download it all again.
static void CheckCardAfterSettingsInstall(void) {
    FakeRunner* runner = [FakeRunner new];
    FakeEnvironment* environment = [FakeEnvironment new];
    SPDFMacAIPythonToolProvider* provider = [[SPDFMacAIPythonToolProvider alloc] initWithRunner:runner
                                                                                    environment:environment];
    SPDFMacAIChatActivity* activity = FakeActivity();
    FakeCall(provider, @{@"code" : @"print(1)"}, FakeContext(activity, YES, nil));
    NSDictionary* card = FakeEntries(activity, SPDFMacAIActivityKindCard).firstObject;
    CHECK([card[SPDFMacAIActivityBodyKey] isEqual:SPDFMacAIPythonInstallBody()] &&
          [card[SPDFMacAIActivityBodyKey] containsString:SPDFMacAIPythonInstallSummary()],
          "the chat card and Settings' sheet share one consent, with the same size and source");
    environment.installed = YES;
    [activity performAction:@"install" forEntry:card[SPDFMacAIActivityIDKey]];
    card = FakeEntries(activity, SPDFMacAIActivityKindCard).firstObject;
    CHECK(environment.installs == 0 && [card[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateDone] &&
          [card[SPDFMacAIActivityStatusKey] hasPrefix:@"Installed."],
          "Install on a card after Python was installed elsewhere just says it is installed");
}

static void CheckSettingsHook(void) {
    NSString* python = [NSString stringWithContentsOfFile:@"mac/SPDFMacAIPythonIntegration.mm"
                                                 encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSRange category =
        [python rangeOfString:@"@implementation ShenzhenMacDelegate (SPDFMacAIPythonSandboxSettingsSource)"];
    NSRange method = [python rangeOfString:@"- (id<SPDFMacAIPythonSandboxSettings>)aiPythonSandboxSettings {\n"
                                           @"    return SPDFMacAIPythonSettingsSource.sharedSource;"];
    CHECK(category.location != NSNotFound && method.location > category.location,
          "the reader hands Settings the shared Python source");
    NSString* settings = [NSString stringWithContentsOfFile:@"mac/SPDFMacAICapabilitiesSettingsIntegration.mm"
                                                   encoding:NSUTF8StringEncoding error:nil] ?: @"";
    CHECK([settings containsString:@"SPDFMacAICapabilitiesState(settings, [self aiPythonSandboxSettings])"] &&
          [settings containsString:
              @"SPDFMacAICapabilitiesPerformAction(action, controller, [self aiPythonSandboxSettings])"],
          "Settings' state and Install… both use it");
}
