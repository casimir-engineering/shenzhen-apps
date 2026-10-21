// The AI page's capabilities section (mac/SPDFMacAICapabilitiesSettings.h) in the real Settings window: defaults,
// bindings to SPDFMacAISettings' switches, persistence through ai-settings.yaml in a temporary folder, the Python
// row's statuses through a fake sandbox, the copy, layout, and the reader's hook lines (source contract, since the
// reader's categories need the whole coordinator to link). Headless: no window is shown, nothing leaves the Mac.
// Arguments: the portable/ directory; optionally a folder to write the section's renders into for review.
#import <Cocoa/Cocoa.h>
#import "../SPDFMacAICapabilitiesSettings.h"
#import "../SPDFMacAISettings.h"

typedef NSDictionary<NSString*, NSString*> PythonStatus;

static int failures;
static void Expect(BOOL ok, NSString* name) {
    if (!ok) { failures++; fprintf(stderr, "FAIL %s\n", name.UTF8String); }
}
static NSString* With(NSString* name, NSString* text) { return [NSString stringWithFormat:@"%@: %@", name, text]; }
static NSView* Find(NSView* view, NSString* identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView* child in view.subviews) { NSView* found = Find(child, identifier); if (found) return found; }
    return nil;
}
static NSButton* Button(NSView* root, NSString* identifier) { return (NSButton*)Find(root, identifier); }
static NSString* Text(NSView* root, NSString* identifier) {
    return [(NSTextField*)Find(root, identifier) stringValue] ?: @"";
}
// Hidden directly or through an ancestor: what the person can actually see.
static BOOL Shown(NSView* view) {
    for (NSView* v = view; v; v = v.superview) if (v.hidden) return NO;
    return view != nil;
}

@interface FakePythonSandbox : NSObject <SPDFMacAIPythonSandboxSettings>
@property(nonatomic) PythonStatus* status;
@property(nonatomic) NSInteger installs;
@property(nonatomic) NSWindow* installWindow;
@property(nonatomic, copy) void (^update)(PythonStatus*);
@end
@implementation FakePythonSandbox
- (PythonStatus*)pythonSandboxSettingsStatus { return self.status; }
- (void)installPythonSandboxForWindow:(NSWindow*)window update:(void (^)(PythonStatus* status))update {
    self.installs++; self.installWindow = window; self.update = update;
}
@end

static NSString* const Location = @"Library/Application Support/ShenzhenPDF/assistant-python";
static NSString* const Download = @"Installing downloads about 40 MB from pypi.org once.";
// The chat card's sentence, which the row shows when the source gives none.
static NSString* const Summary = @"Installing downloads about 40 MB from the Python Package Index (pypi.org) once and "
    "keeps it in ShenzhenPDF’s folder, using about 200 MB of disk.";

static SPDFMacUnifiedSettingsController* AIPage(NSDictionary* state, NSMutableArray* changes, NSMutableArray* actions) {
    SPDFMacUnifiedSettingsController* controller = [[SPDFMacUnifiedSettingsController alloc] initWithState:state];
    controller.settingsChanged = ^(NSDictionary* change) { [changes addObject:change]; };
    controller.actionHandler = ^(NSString* action) { [actions addObject:action]; };
    [controller selectSection:@"ai"];
    [controller.window.contentView layoutSubtreeIfNeeded];
    return controller;
}

static SPDFMacAISettings* Settings(NSURL* URL) {
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:URL];
    NSError* error = nil;
    Expect([settings load:&error], With(@"settings load", error.description));
    return settings;
}

static void TestDefaults(NSURL* URL) {
    NSString *web = SPDFMacAIWebSearchEnabledKey, *helpers = SPDFMacAISubagentsEnabledKey;
    NSDictionary* state = SPDFMacAICapabilitiesState(Settings(URL), nil);
    Expect([state[web] isEqual:@YES] && [state[SPDFMacAIPythonEnabledKey] isEqual:@YES] &&
           [state[helpers] isEqual:@YES], @"every capability is on before the person chooses");
    Expect([state[SPDFMacAIPythonStatusKey] isEqual:@""], @"no Python status without the Python sandbox's area");
    SPDFMacUnifiedSettingsController* page = AIPage(@{}, [NSMutableArray array], [NSMutableArray array]);
    NSView* root = page.window.contentView;
    Expect(Button(root, web).state == NSControlStateValueOn && Button(root, helpers).state == NSControlStateValueOn,
           @"a state without the switches draws them on, as saved settings default");
    Expect(Find(root, @"aiPythonRow") && !Shown(Find(root, @"aiPythonRow")),
           @"no Python row when nothing can say whether Python is installed");
}

static void TestBindings(void) {
    NSString *webKey = SPDFMacAIWebSearchEnabledKey, *helpersKey = SPDFMacAISubagentsEnabledKey;
    NSString* pythonKey = SPDFMacAIPythonEnabledKey;
    NSMutableArray* changes = [NSMutableArray array];
    NSDictionary* state = @{@"aiEnabled" : @YES, @"autoAnalyze" : @NO, webKey : @NO, helpersKey : @YES,
                            pythonKey : @YES, SPDFMacAIPythonStatusKey : SPDFMacAIPythonStatusReady};
    SPDFMacUnifiedSettingsController* page = AIPage(state, changes, [NSMutableArray array]);
    NSView* root = page.window.contentView;
    NSButton *web = Button(root, webKey), *helpers = Button(root, helpersKey), *python = Button(root, pythonKey);
    Expect(web.state == NSControlStateValueOff && helpers.state == NSControlStateValueOn &&
           python.state == NSControlStateValueOn && Shown(python), @"switches show the saved settings");
    [web performClick:nil]; [helpers performClick:nil]; [python performClick:nil];
    Expect([changes isEqual:@[@{webKey : @YES}, @{helpersKey : @NO}, @{pythonKey : @NO}]],
           With(@"each switch reports its own settings key", changes.description));
    [page updateState:@{webKey : @NO, helpersKey : @YES}];
    Expect(Find(root, webKey) == web && web.state == NSControlStateValueOff && helpers.state == NSControlStateValueOn,
           @"a change from the host updates the switches in place");
    NSStackView* content = [page valueForKey:@"content"];
    NSUInteger (^index)(NSString*) = ^NSUInteger(NSString* identifier) {
        NSView* view = Find(root, identifier);
        while (view && view.superview != content) view = view.superview;
        return view ? [content.arrangedSubviews indexOfObject:view] : NSNotFound;
    };
    NSArray* order = @[@"aiEnabled", @"autoAnalyze", @"aiWebSearchEnabledGroup", @"aiSubagentsEnabledGroup",
                       @"aiPythonRow"];
    BOOL ordered = index(order.lastObject) != NSNotFound;
    for (NSUInteger i = 1; i < order.count; i++) ordered = ordered && index(order[i - 1]) < index(order[i]);
    Expect(ordered, @"document chat, preparation, web, helpers and Python read in that order on the AI page");
}

static void TestPersistence(NSURL* URL) {
    NSString *web = SPDFMacAIWebSearchEnabledKey, *helpers = SPDFMacAISubagentsEnabledKey;
    NSString* python = SPDFMacAIPythonEnabledKey;
    SPDFMacAISettings* settings = Settings(URL);
    Expect(!SPDFMacAICapabilitiesApply(settings, @{@"model" : @"x/y", python : @"no"}) && settings.aiPythonEnabled,
           @"other keys, and values that are not switches, are left alone");
    // Through the window: each switch's change is applied and saved as the reader does, then read back.
    SPDFMacUnifiedSettingsController* page =
        [[SPDFMacUnifiedSettingsController alloc] initWithState:SPDFMacAICapabilitiesState(settings, nil)];
    page.settingsChanged = ^(NSDictionary* change) {
        SPDFMacAISettings* current = Settings(URL);
        Expect(SPDFMacAICapabilitiesApply(current, change), @"a switch's change applies to the settings");
        NSError* error = nil;
        Expect([current save:&error], With(@"settings save", error.description));
    };
    [page selectSection:@"ai"];
    [Button(page.window.contentView, web) performClick:nil];
    [Button(page.window.contentView, helpers) performClick:nil];
    NSString* YAML = [NSString stringWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:nil] ?: @"";
    Expect([YAML containsString:@"web_search_enabled: false\n"] && [YAML containsString:@"subagents_enabled: false\n"]
           && [YAML containsString:@"python_enabled: true\n"], With(@"switches are saved in ai-settings.yaml", YAML));
    NSDictionary* reread = SPDFMacAICapabilitiesState(Settings(URL), nil);
    Expect([reread[web] isEqual:@NO] && [reread[helpers] isEqual:@NO] && [reread[python] isEqual:@YES],
           @"switches read back as saved");
    SPDFMacUnifiedSettingsController* reopened = AIPage(reread, [NSMutableArray array], [NSMutableArray array]);
    Expect(Button(reopened.window.contentView, web).state == NSControlStateValueOff,
           @"Settings opened again shows the saved choice");
    // Another window that loaded before the change, saving a different switch, keeps this one.
    settings.aiPythonEnabled = NO;
    NSError* error = nil;
    Expect([settings save:&error], @"second window saves");
    reread = SPDFMacAICapabilitiesState(Settings(URL), nil);
    Expect([reread[web] isEqual:@NO] && [reread[python] isEqual:@NO], @"switches merge per field across windows");
}

static void TestPythonRow(void) {
    NSString* home = [NSHomeDirectory() stringByAppendingPathComponent:Location];
    NSString* shown = [@"~/" stringByAppendingString:Location];
    NSString *statusKey = SPDFMacAIPythonStatusKey, *locationKey = SPDFMacAIPythonLocationKey;
    NSString *detailKey = SPDFMacAIPythonDetailKey, *pythonKey = SPDFMacAIPythonEnabledKey;
    FakePythonSandbox* sandbox = [FakePythonSandbox new];
    sandbox.status = @{statusKey : SPDFMacAIPythonStatusNotInstalled, locationKey : home,
                       SPDFMacAIPythonDownloadKey : Download};
    SPDFMacAISettings* settings = Settings([NSURL fileURLWithPath:@"/nonexistent/ai-settings.yaml"]);
    NSMutableDictionary* state = [SPDFMacAICapabilitiesState(settings, sandbox) mutableCopy];
    state[pythonKey] = @NO;
    NSMutableArray *changes = [NSMutableArray array], *actions = [NSMutableArray array];
    SPDFMacUnifiedSettingsController* page = AIPage(state, changes, actions);
    NSView* root = page.window.contentView;
    NSView* row = Find(root, @"aiPythonRow");
    NSButton *install = Button(root, SPDFMacAIPythonInstallAction), *use = Button(root, pythonKey);
    Expect(Shown(row) && Shown(use) && use.enabled && use.state == NSControlStateValueOff &&
           [Text(root, @"aiPythonStatusLabel") isEqual:@"Not installed"] && Shown(install) &&
           [install.title isEqual:@"Install…"], @"not installed: the switch, the status and Install…");
    Expect([Text(root, @"aiPythonStatusDetail") isEqual:Download],
           With(@"switched off, what installing fetches and nothing about the chat asking", Text(root,
                @"aiPythonStatusDetail")));
    [install performClick:nil];
    Expect([changes isEqual:@[@{pythonKey : @YES}]] && [actions isEqual:@[SPDFMacAIPythonInstallAction]],
           @"Install… turns Python on, then asks the host to install");
    [page updateState:changes.lastObject];
    Expect([Text(root, @"aiPythonStatusDetail") hasSuffix:@"asks in the chat the first time it needs Python."],
           @"switched on, the row adds that the chat asks too");
    [changes removeAllObjects]; [actions removeAllObjects];
    [install performClick:nil];
    Expect(!changes.count && actions.count == 1, @"Install… with Python already on only asks to install");

    Expect(!SPDFMacAICapabilitiesPerformAction(@"requestModels", page, sandbox) && sandbox.installs == 0,
           @"other actions are left to the host");
    Expect(SPDFMacAICapabilitiesPerformAction(SPDFMacAIPythonInstallAction, page, sandbox) && sandbox.installs == 1 &&
           sandbox.installWindow == page.window, @"Install… reaches the Python source with the Settings window");
    Expect(SPDFMacAICapabilitiesPerformAction(SPDFMacAIPythonInstallAction, page, nil),
           @"Install… without a source is still the section's, and does nothing");
    sandbox.update(@{statusKey : SPDFMacAIPythonStatusInstalling, locationKey : home,
                     detailKey : @"Downloading numpy, pandas and matplotlib…"});
    Expect([Text(root, @"aiPythonStatusLabel") isEqual:@"Installing…"] && !Shown(install) &&
           [Text(root, @"aiPythonStatusDetail") isEqual:@"Downloading numpy, pandas and matplotlib…"],
           @"installing: the step it is on, with nothing to press");
    sandbox.update(@{statusKey : SPDFMacAIPythonStatusNotInstalled, locationKey : home,
                     detailKey : @"Could not download numpy, pandas and matplotlib. Check the internet connection, "
                                 @"then try again."});
    NSString* detail = Text(root, @"aiPythonStatusDetail");
    Expect(Shown(install) && [detail hasPrefix:@"Could not download"] && [detail containsString:Summary],
           With(@"a stopped install says why first, then offers Install… again with what it fetches", detail));
    sandbox.update(@{statusKey : SPDFMacAIPythonStatusReady, locationKey : home});
    NSTextField* line = (NSTextField*)Find(root, @"aiPythonStatusLabel");
    Expect([line.stringValue isEqual:[@"Installed in " stringByAppendingString:shown]] && [line.toolTip isEqual:home] &&
           Shown(use) && use.state == NSControlStateValueOn && !Shown(install) &&
           !Shown(Find(root, @"aiPythonStatusDetail")),
           With(@"ready: where it lives, the full folder on hover, and no stale reason", line.stringValue));
    Expect(Find(root, @"aiPythonRow") == row && Find(root, SPDFMacAIPythonInstallAction) == install,
           @"status changes update the row in place");
    sandbox.update(@{statusKey : SPDFMacAIPythonStatusUnavailable});
    Expect([Text(root, @"aiPythonStatusLabel") isEqual:@"Not available"] && !Shown(install) && !use.enabled &&
           use.state == NSControlStateValueOff &&
           [Text(root, @"aiPythonStatusDetail") hasPrefix:@"This Mac can’t keep Python cut off"],
           @"unavailable: says why, and the switch is drawn off and cannot be changed");
    // Saved on, but unavailable: the box is drawn off without a change leaving, so the saved choice survives.
    NSMutableArray* savedChanges = [NSMutableArray array];
    NSDictionary* savedState = @{pythonKey : @YES, statusKey : SPDFMacAIPythonStatusUnavailable};
    SPDFMacUnifiedSettingsController* savedOn = AIPage(savedState, savedChanges, [NSMutableArray array]);
    NSButton* savedUse = Button(savedOn.window.contentView, pythonKey);
    Expect(savedUse.state == NSControlStateValueOff && !savedUse.enabled && savedChanges.count == 0,
           @"a Mac that cannot run Python draws the box off though the setting stays on, emitting no change");
    sandbox.update(@{statusKey : SPDFMacAIPythonStatusUnavailable, detailKey : @"This copy is incomplete."});
    Expect([Text(root, @"aiPythonStatusDetail") isEqual:@"This copy is incomplete."], @"the source's own reason wins");
    sandbox.update(@{statusKey : @"bogus"});
    Expect(!Shown(row), @"an unknown status hides the row rather than guessing");
    NSDictionary* kept = SPDFMacAIPythonSettingsStatus(@{statusKey : @"ready", locationKey : @5, @"other" : @"x"});
    Expect([kept isEqual:@{statusKey : @"ready", locationKey : @"", SPDFMacAIPythonDownloadKey : @"",
                           detailKey : @""}], With(@"only known keys and strings reach Settings", kept.description));
    NSString* fallback = SPDFMacAIPythonSettingsDetail(@{statusKey : SPDFMacAIPythonStatusNotInstalled});
    Expect([fallback hasPrefix:Summary], With(@"the chat card's sentence when the source gives none", fallback));
}

static void TestWizardAndCopy(void) {
    NSString *webKey = SPDFMacAIWebSearchEnabledKey, *helpersKey = SPDFMacAISubagentsEnabledKey;
    SPDFMacUnifiedSettingsController* wizard = [[SPDFMacUnifiedSettingsController alloc]
        initWithState:@{@"setupWizard" : @YES, @"wizardStep" : @2, SPDFMacAIPythonStatusKey : @"notInstalled"}];
    NSView* root = wizard.window.contentView;
    Expect(Find(root, @"model") && !Find(root, webKey) && !Find(root, @"aiPythonRow"),
           @"the setup wizard keeps to connection and model");
    [wizard updateState:@{SPDFMacAIPythonStatusKey : @"ready", webKey : @NO}];
    Expect(!Find(root, @"aiPythonRow"), @"updates while the wizard shows do not add the section");

    SPDFMacUnifiedSettingsController* page = AIPage(@{SPDFMacAIPythonStatusKey : @"notInstalled"},
                                                   [NSMutableArray array], [NSMutableArray array]);
    root = page.window.contentView;
    NSString *web = Text(root, @"aiWebSearchEnabledDetail"), *helpers = Text(root, @"aiSubagentsEnabledDetail");
    Expect([Button(root, webKey).title isEqual:@"Let the assistant search the web"] &&
           [Button(root, helpersKey).title isEqual:@"Let the assistant split big tasks into parts"] &&
           [Button(root, SPDFMacAIPythonEnabledKey).title isEqual:@"Let the assistant run Python"], @"switch labels");
    // Exact: search terms go to OpenRouter's search service; pages are fetched by this Mac itself, so no other
    // service sees the address, and what the assistant reads goes to OpenRouter with the request.
    Expect([web isEqual:@"Search terms go to OpenRouter’s search service, and searches use credits. Pages are read "
                         "from this Mac, and what the assistant reads goes to OpenRouter."],
           With(@"web says where search terms and pages go, and the cost", web));
    Expect([helpers containsString:@"up to four parts"] && [helpers containsString:@"can’t change or send anything"]
           && [helpers containsString:@"more OpenRouter credits"],
           With(@"helpers say what they can do and cost", helpers));
    NSMutableArray* words = [@[web, helpers, Text(root, @"aiPythonDescription")] mutableCopy];
    for (NSString* status in @[@"notInstalled", @"installing", @"ready", @"unavailable"]) {
        [words addObject:SPDFMacAIPythonSettingsStatusLine(@{SPDFMacAIPythonStatusKey : status})];
        [words addObject:SPDFMacAIPythonSettingsDetail(@{SPDFMacAIPythonStatusKey : status})];
    }
    for (NSString* text in words)
        for (NSString* mechanism in @[@"tool", @"token", @"subagent", @"profile", @"venv", @"model", @"process",
                                      @"sandbox"])
            Expect(![text.lowercaseString containsString:mechanism],
                   [NSString stringWithFormat:@"no '%@' in what the person reads: %@", mechanism, text]);
}

static void Render(NSView* view, NSString* path, NSInteger scale) {
    NSRect bounds = view.bounds;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)NSWidth(bounds) * scale pixelsHigh:(NSInteger)NSHeight(bounds) * scale bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = bounds.size;
    [view cacheDisplayInRect:bounds toBitmapImageRep:rep];
    Expect([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],
           With(@"render saved", path));
}

// Width, wrapping and whole-control clicks at the window's two sizes; optional renders, light and dark, 1x and 2x.
static void TestLayout(NSString* renders) {
    NSArray* sizes = @[[NSValue valueWithSize:NSMakeSize(760, 612)], [NSValue valueWithSize:NSMakeSize(650, 540)]];
    for (NSString* status in @[@"notInstalled", @"ready"]) {
        NSMutableArray* explanations = [@[@"aiWebSearchEnabledDetail", @"aiSubagentsEnabledDetail",
                                          @"aiPythonDescription"] mutableCopy];
        if ([status isEqual:SPDFMacAIPythonStatusNotInstalled]) [explanations addObject:@"aiPythonStatusDetail"];
        // Longer than the narrow window, so the folder has to be shortened rather than wrapped.
        NSString* home = [NSHomeDirectory() stringByAppendingPathComponent:[Location stringByAppendingString:
            @"/with/a/long/folder/name/to/show/how/the/line/is/shortened/in/its/middle"]];
        NSDictionary* state = @{@"connected" : @YES, SPDFMacAIPythonStatusKey : status,
                                SPDFMacAIPythonLocationKey : home};
        SPDFMacUnifiedSettingsController* page = AIPage(state, [NSMutableArray array], [NSMutableArray array]);
        for (NSValue* size in sizes) {
            [page.window setContentSize:size.sizeValue];
            NSView* root = page.window.contentView;
            [root layoutSubtreeIfNeeded];
            NSStackView* content = [page valueForKey:@"content"];
            for (NSView* child in content.arrangedSubviews)
                Expect(NSMaxX([child alignmentRectForFrame:child.frame]) <= NSWidth(content.bounds) + 1,
                       @"the section never overflows the page");
            for (NSString* identifier in explanations) {
                NSTextField* field = (NSTextField*)Find(root, identifier);
                NSSize needed = [field.cell cellSizeForBounds:NSMakeRect(0, 0, NSWidth(field.frame), CGFLOAT_MAX)];
                Expect(NSWidth(field.frame) > 300 && needed.height <= NSHeight(field.frame) + 1,
                       With(@"explanations wrap without clipping", identifier));
            }
            NSTextField* line = (NSTextField*)Find(root, @"aiPythonStatusLabel");
            CGFloat oneLine = [line.cell cellSizeForBounds:NSMakeRect(0, 0, CGFLOAT_MAX, CGFLOAT_MAX)].height;
            Expect(Shown(line) && NSHeight(line.frame) <= oneLine + 1 && line.maximumNumberOfLines == 1 &&
                   line.lineBreakMode == NSLineBreakByTruncatingMiddle &&
                   NSMaxX([line convertRect:line.bounds toView:root]) <= NSWidth(root.bounds),
                   With(@"the status stays on one line, shortening a long folder in its middle", line.stringValue));
            BOOL ready = [status isEqual:SPDFMacAIPythonStatusReady];
            NSView* target = Find(root, ready ? SPDFMacAIPythonEnabledKey : SPDFMacAIPythonInstallAction);
            [content scrollRectToVisible:[content convertRect:target.bounds fromView:target]];
            NSSize extent = target.bounds.size;
            for (NSValue* corner in @[[NSValue valueWithPoint:NSMakePoint(2, 2)],
                                      [NSValue valueWithPoint:NSMakePoint(extent.width - 2, extent.height - 2)]]) {
                NSPoint point = [target convertPoint:corner.pointValue toView:nil];
                NSView* hit = [root hitTest:[root.superview convertPoint:point fromView:nil]];
                Expect(hit == target || [hit isDescendantOf:target],
                       @"Python's control takes clicks across its bounds");
            }
            if (!renders) continue;
            // Tall enough for the whole page, and the window's own surface, so dark renders have their background.
            [page.window setContentSize:NSMakeSize(size.sizeValue.width, 1050)];
            [root layoutSubtreeIfNeeded];
            for (NSString* appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
                page.window.appearance = [NSAppearance appearanceNamed:appearance];
                for (NSInteger scale = 1; scale <= 2; scale++) {
                    NSString* tone = [appearance isEqual:NSAppearanceNameAqua] ? @"light" : @"dark";
                    NSString* name = [NSString stringWithFormat:@"ai-%@-%.0f-%@-%ldx.png", status,
                                                                size.sizeValue.width, tone, (long)scale];
                    Render(root, [renders stringByAppendingPathComponent:name], scale);
                }
            }
        }
        Expect(!page.window.visible, @"verification never shows a window");
    }
}

// The reader's lines, which link only with the whole coordinator: where each hook sits in its method.
static void TestReaderHooks(NSString* portable) {
    NSString* (^source)(NSString*) = ^NSString*(NSString* path) {
        return [NSString stringWithContentsOfFile:[portable stringByAppendingPathComponent:path]
                                         encoding:NSUTF8StringEncoding error:nil] ?: @"";
    };
    BOOL (^before)(NSString*, NSString*, NSString*) = ^BOOL(NSString* text, NSString* first, NSString* second) {
        NSRange a = [text rangeOfString:first], b = [text rangeOfString:second];
        return a.location != NSNotFound && b.location != NSNotFound && a.location < b.location;
    };
    NSString* window = source(@"mac/SPDFMacUnifiedSettings.mm");
    NSRange start = [window rangeOfString:@"- (void)buildAI {"];
    NSRange end = [window rangeOfString:@"- (void)buildKeyAlternative"];
    NSString* buildAI = start.location != NSNotFound && end.location != NSNotFound && end.location > start.location
        ? [window substringWithRange:NSMakeRange(start.location, end.location - start.location)] : @"";
    Expect(before(buildAI, @"aiUploadDisclosure", @"[self buildAICapabilities];"),
           @"the AI page builds the section after the wizard's early return");
    Expect(before(window, @"- (void)updateState:", @"[self refreshAICapabilities:state];"),
           @"Settings passes every state change to the section");
    NSString* reader = source(@"mac/SPDFMacAISettingsIntegration.mm");
    Expect(before(reader, @"[self aiCapabilitiesSettingsState:ai]", @"- (void)showUnifiedSettings:"),
           @"the Settings state includes the section's");
    Expect(before(reader, @"SPDFMacAICapabilitiesApply(ai,changes);", @"[ai save:&error];"),
           @"switch changes are applied before the reader saves");
    Expect(before(reader, @"[self performAICapabilitiesSettingsAction:action controller:controller]) return;",
                  @"[action isEqual:@\"requestModels\"]"), @"Install… reaches the section's action");
}

int main(int argc, char** argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString* portable = argc > 1 ? @(argv[1]) : @".";
        NSString* renders = argc > 2 ? @(argv[2]) : nil;
        NSString* folder = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"szf-capabilities-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        TestDefaults([NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"defaults/ai-settings.yaml"]]);
        TestBindings();
        TestPersistence([NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"saved/ai-settings.yaml"]]);
        TestPythonRow();
        TestWizardAndCopy();
        TestLayout(renders);
        TestReaderHooks(portable);
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
        Expect(![NSFileManager.defaultManager fileExistsAtPath:folder], @"the temporary settings folder is removed");
    }
    if (failures) { fprintf(stderr, "SPDFMacAICapabilitiesSettingsTests: %d failures\n", failures); return 1; }
    puts("SPDFMacAICapabilitiesSettingsTests passed");
    return 0;
}
