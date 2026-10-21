// The AI page's section of what the assistant may do (SPDFMacAICapabilitiesSettings.h). Kept apart from the Settings
// controller so that file stays within its size cap and this section can be tested with the window alone.

#import "SPDFMacAICapabilitiesSettings.h"
#import "SPDFMacAIPythonInstall.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacCollectionStyle.h"

NSString* const SPDFMacAIWebSearchEnabledKey = @"aiWebSearchEnabled";
NSString* const SPDFMacAIPythonEnabledKey = @"aiPythonEnabled";
NSString* const SPDFMacAISubagentsEnabledKey = @"aiSubagentsEnabled";
NSString* const SPDFMacAIPythonStatusKey = @"aiPythonStatus";
NSString* const SPDFMacAIPythonLocationKey = @"aiPythonLocation";
NSString* const SPDFMacAIPythonDownloadKey = @"aiPythonDownload";
NSString* const SPDFMacAIPythonDetailKey = @"aiPythonDetail";
NSString* const SPDFMacAIPythonStatusNotInstalled = @"notInstalled";
NSString* const SPDFMacAIPythonStatusInstalling = @"installing";
NSString* const SPDFMacAIPythonStatusReady = @"ready";
NSString* const SPDFMacAIPythonStatusUnavailable = @"unavailable";
NSString* const SPDFMacAIPythonInstallAction = @"installPython";

// Read by someone deciding whether to keep each switch on: what leaves the Mac, who sees it, what it costs.
static NSString* const WebLabel = @"Let the assistant search the web";
// Search terms reach OpenRouter's search service; pages and PDFs are fetched by this Mac itself (no other service sees
// the address), and what the assistant reads goes to OpenRouter like the rest of the request.
static NSString* const WebDetail = @"Search terms go to OpenRouter’s search service, and searches use credits. Pages "
    "are read from this Mac, and what the assistant reads goes to OpenRouter.";
static NSString* const HelpersLabel = @"Let the assistant split big tasks into parts";
static NSString* const HelpersDetail = @"For bigger requests, such as comparing several documents, the assistant can "
    "work on up to four parts at the same time. Parts only read: they can’t change or send anything. This uses more "
    "OpenRouter credits.";
static NSString* const PythonLabel = @"Let the assistant run Python";
static NSString* const PythonPurpose = @"The assistant can use Python to calculate and make charts. Its code runs cut "
    "off from the internet and from your files.";
// Only while the switch is on: switched off, the assistant never asks.
static NSString* const PythonAsksInChat = @"The assistant also asks in the chat the first time it needs Python.";
static NSString* const PythonUnavailable = @"This Mac can’t keep Python cut off from the internet and your files, so "
    "the assistant doesn’t use it.";

static NSArray<NSString*>* SwitchKeys(void) {
    return @[SPDFMacAIWebSearchEnabledKey, SPDFMacAIPythonEnabledKey, SPDFMacAISubagentsEnabledKey];
}
static NSArray<NSString*>* PythonStatuses(void) {
    return @[SPDFMacAIPythonStatusNotInstalled, SPDFMacAIPythonStatusInstalling, SPDFMacAIPythonStatusReady,
             SPDFMacAIPythonStatusUnavailable];
}
// Every switch defaults to on in SPDFMacAISettings, so a state without the key must not draw it off.
static NSControlStateValue SwitchState(NSDictionary* state, NSString* key) {
    id value = state[key];
    return !value || [value boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
}

NSDictionary<NSString*, id>* SPDFMacAICapabilitiesState(SPDFMacAISettings* settings,
                                                       id<SPDFMacAIPythonSandboxSettings> python) {
    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    for (NSString* key in SwitchKeys()) state[key] = @([[settings valueForKey:key] boolValue]);
    [state addEntriesFromDictionary:SPDFMacAIPythonSettingsStatus([python pythonSandboxSettingsStatus])];
    return state;
}

BOOL SPDFMacAICapabilitiesApply(SPDFMacAISettings* settings, NSDictionary* changes) {
    BOOL applied = NO;
    for (NSString* key in SwitchKeys()) {
        id value = changes[key];
        if (![value isKindOfClass:NSNumber.class]) continue;
        [settings setValue:@([value boolValue]) forKey:key];
        applied = YES;
    }
    return applied;
}

BOOL SPDFMacAICapabilitiesPerformAction(NSString* action, SPDFMacUnifiedSettingsController* controller,
                                        id<SPDFMacAIPythonSandboxSettings> python) {
    if (![action isEqual:SPDFMacAIPythonInstallAction]) return NO;
    __weak SPDFMacUnifiedSettingsController* weakController = controller;
    [python installPythonSandboxForWindow:controller.window update:^(NSDictionary* status) {
        [weakController updateState:SPDFMacAIPythonSettingsStatus(status)];
    }];
    return YES;
}

NSDictionary<NSString*, NSString*>* SPDFMacAIPythonSettingsStatus(NSDictionary* status) {
    NSMutableDictionary* kept = [NSMutableDictionary dictionary];
    id value = status[SPDFMacAIPythonStatusKey];
    kept[SPDFMacAIPythonStatusKey] = [PythonStatuses() containsObject:value] ? value : @"";
    for (NSString* key in @[SPDFMacAIPythonLocationKey, SPDFMacAIPythonDownloadKey, SPDFMacAIPythonDetailKey]) {
        id text = status[key];
        kept[key] = [text isKindOfClass:NSString.class] ? text : @"";
    }
    return kept;
}

NSString* SPDFMacAIPythonSettingsStatusLine(NSDictionary* state) {
    NSDictionary* python = SPDFMacAIPythonSettingsStatus(state);
    NSString* status = python[SPDFMacAIPythonStatusKey], *location = python[SPDFMacAIPythonLocationKey];
    if ([status isEqual:SPDFMacAIPythonStatusNotInstalled]) return @"Not installed";
    if ([status isEqual:SPDFMacAIPythonStatusInstalling]) return @"Installing…";
    if ([status isEqual:SPDFMacAIPythonStatusReady])
        return location.length ? [@"Installed in " stringByAppendingString:location.stringByAbbreviatingWithTildeInPath]
                               : @"Installed";
    if ([status isEqual:SPDFMacAIPythonStatusUnavailable]) return @"Not available";
    return @"";
}

NSString* SPDFMacAIPythonSettingsDetail(NSDictionary* state) {
    NSDictionary* python = SPDFMacAIPythonSettingsStatus(state);
    NSString* status = python[SPDFMacAIPythonStatusKey], *detail = python[SPDFMacAIPythonDetailKey];
    NSMutableArray* sentences = [NSMutableArray array];
    if ([status isEqual:SPDFMacAIPythonStatusUnavailable]) {
        [sentences addObject:detail.length ? detail : PythonUnavailable];
    } else {
        // First what happened (why the last install stopped, the step an install is on), then what to expect.
        if (detail.length) [sentences addObject:detail];
        if ([status isEqual:SPDFMacAIPythonStatusNotInstalled]) {
            NSString* download = python[SPDFMacAIPythonDownloadKey];
            [sentences addObject:download.length ? download : SPDFMacAIPythonInstallSummary()];
            if (SwitchState(state, SPDFMacAIPythonEnabledKey) == NSControlStateValueOn)
                [sentences addObject:PythonAsksInChat];
        }
    }
    return [sentences componentsJoinedByString:@" "];
}

// Built by SPDFMacUnifiedSettings.mm; declared here so this section is laid out like the rest of the page.
@interface SPDFMacUnifiedSettingsController (SPDFMacAICapabilitiesBuilding)
- (NSDictionary*)state;
- (NSMutableDictionary<NSString*, NSControl*>*)controls;
- (NSStackView*)content;
- (void)add:(NSView*)view;
- (void)divider;
- (void)text:(NSString*)text size:(CGFloat)size bold:(BOOL)bold secondary:(BOOL)secondary;
- (NSStackView*)row:(NSString*)title detail:(NSString*)detail control:(NSView*)control;
- (NSButton*)toggle:(NSString*)key label:(NSString*)label;
- (NSButton*)button:(NSString*)title action:(SEL)action key:(NSString*)key;
- (void)emit:(NSDictionary*)change;
@end

@implementation SPDFMacUnifiedSettingsController (SPDFMacAICapabilities)
- (void)buildAICapabilities {
    [self add:[self toggle:@"aiEnabled" label:@"Enable document chat"]];
    [self add:[self toggle:@"autoAnalyze" label:@"Prepare summaries, tags and missing chapters automatically"]];
    [self text:@"Automatic preparation sends document text to OpenRouter and its provider after opening, in the "
        "background. It uses paid tokens. Existing chapters stay intact; generated information is cached for "
        "unchanged documents." size:12 bold:NO secondary:YES];
    [self text:@"Requests require providers that do not train on your content and retain no request data. If no "
        "eligible provider is available, the request stops. You can stop a task at any time." size:12 bold:NO
        secondary:YES];
    [self divider];
    [self add:[self capabilitySwitch:SPDFMacAIWebSearchEnabledKey label:WebLabel detail:WebDetail]];
    [self add:[self capabilitySwitch:SPDFMacAISubagentsEnabledKey label:HelpersLabel detail:HelpersDetail]];
    [self buildPythonRow];
}
// Wrapping 12 pt secondary text, the explanation style under every switch in the section.
static NSTextField* WrappingText(NSString* text, NSString* identifier) {
    NSTextField* field = SPDFCollectionText(text, 12, NSFontWeightRegular, YES);
    field.identifier = identifier;
    field.lineBreakMode = NSLineBreakByWordWrapping; field.maximumNumberOfLines = 0;
    field.cell.wraps = YES; field.cell.scrollable = NO;
    return field;
}
// The checkbox with what lies beneath its title, lined up under the words, so each explanation reads as belonging
// to its own switch.
- (NSView*)switchGroup:(NSButton*)box identifier:(NSString*)identifier below:(NSView*)below {
    NSView* group = [NSView new];
    group.identifier = identifier;
    for (NSView* view in @[box, below]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [group addSubview:view];
    }
    // The checkbox image and its gap: the title starts here.
    CGFloat indent = NSMinX([box.cell titleRectForBounds:NSMakeRect(0, 0, 400, 18)]);
    [NSLayoutConstraint activateConstraints:@[
        [box.topAnchor constraintEqualToAnchor:group.topAnchor],
        [box.leadingAnchor constraintEqualToAnchor:group.leadingAnchor],
        [box.trailingAnchor constraintLessThanOrEqualToAnchor:group.trailingAnchor],
        [below.topAnchor constraintEqualToAnchor:box.bottomAnchor constant:4],
        [below.leadingAnchor constraintEqualToAnchor:group.leadingAnchor constant:indent],
        [below.trailingAnchor constraintEqualToAnchor:group.trailingAnchor],
        [below.bottomAnchor constraintEqualToAnchor:group.bottomAnchor],
    ]];
    return group;
}
- (NSView*)capabilitySwitch:(NSString*)key label:(NSString*)label detail:(NSString*)detail {
    NSButton* box = [self toggle:key label:label];
    box.state = SwitchState(self.state, key);
    return [self switchGroup:box identifier:[key stringByAppendingString:@"Group"]
                       below:WrappingText(detail, [key stringByAppendingString:@"Detail"])];
}
// Laid out like the two switches above it, with the install status and Install… under the explanation.
- (void)buildPythonRow {
    NSButton* use = [self toggle:SPDFMacAIPythonEnabledKey label:PythonLabel];
    NSTextField* purpose = WrappingText(PythonPurpose, @"aiPythonDescription");
    NSTextField* status = SPDFCollectionText(@"", 12, NSFontWeightMedium, NO);
    status.identifier = @"aiPythonStatusLabel";
    // One line whatever the width: a long folder is shortened in its middle, never wrapped partway through.
    status.lineBreakMode = NSLineBreakByTruncatingMiddle; status.maximumNumberOfLines = 1;
    status.cell.wraps = NO; status.cell.scrollable = NO; status.usesSingleLineMode = YES;
    [status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton* install = [self button:@"Install…" action:@selector(installPython:) key:SPDFMacAIPythonInstallAction];
    install.accessibilityLabel = @"Install Python for the assistant";
    NSStackView* line = [NSStackView stackViewWithViews:@[status, install]];
    line.spacing = 12; line.alignment = NSLayoutAttributeCenterY;
    NSTextField* detail = WrappingText(@"", @"aiPythonStatusDetail");
    NSStackView* column = [NSStackView stackViewWithViews:@[purpose, line, detail]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical; column.alignment = NSLayoutAttributeLeading;
    column.spacing = 4;
    [column setCustomSpacing:6 afterView:purpose];
    [NSLayoutConstraint activateConstraints:@[
        [purpose.widthAnchor constraintEqualToAnchor:column.widthAnchor],
        [detail.widthAnchor constraintEqualToAnchor:column.widthAnchor],
        [line.widthAnchor constraintLessThanOrEqualToAnchor:column.widthAnchor],
    ]];
    [self add:[self switchGroup:use identifier:@"aiPythonRow" below:column]];
    for (NSTextField* field in @[status, purpose, detail]) self.controls[field.identifier] = field;
    self.controls[SPDFMacAIPythonInstallAction] = install;
    [self refreshPython];
}
- (void)refreshPython {
    NSView* row = nil;
    for (NSView* view in self.content.arrangedSubviews)
        if ([view.identifier isEqual:@"aiPythonRow"]) row = view;
    if (!row) return; // Another page, or the setup wizard's AI step, which has no such section.
    NSDictionary* state = self.state;
    NSDictionary* python = SPDFMacAIPythonSettingsStatus(state);
    NSString* status = python[SPDFMacAIPythonStatusKey];
    row.hidden = !status.length;
    NSButton* use = (NSButton*)self.controls[SPDFMacAIPythonEnabledKey];
    BOOL unavailable = [status isEqual:SPDFMacAIPythonStatusUnavailable];
    // Drawn off while Python cannot run here, so the box matches the line under it; the saved setting is untouched
    // (this only reads state, never emits), so turning Python back on elsewhere brings the tick back.
    use.state = unavailable ? NSControlStateValueOff : SwitchState(state, SPDFMacAIPythonEnabledKey);
    // Nothing the switch could do on a Mac that cannot run Python; the line under it says why.
    use.enabled = !unavailable;
    NSTextField* line = (NSTextField*)self.controls[@"aiPythonStatusLabel"];
    line.stringValue = SPDFMacAIPythonSettingsStatusLine(state);
    line.toolTip = [status isEqual:SPDFMacAIPythonStatusReady] && [python[SPDFMacAIPythonLocationKey] length]
        ? python[SPDFMacAIPythonLocationKey] : nil;
    self.controls[SPDFMacAIPythonInstallAction].hidden = ![status isEqual:SPDFMacAIPythonStatusNotInstalled];
    NSTextField* detail = (NSTextField*)self.controls[@"aiPythonStatusDetail"];
    detail.stringValue = SPDFMacAIPythonSettingsDetail(state);
    detail.hidden = !detail.stringValue.length;
}
- (void)installPython:(id)sender {
    (void)sender;
    // Asking to install is asking to use it: a switch turned off earlier would leave the fresh install unused, with
    // its checkbox only appearing once the install is ready.
    if (SwitchState(self.state, SPDFMacAIPythonEnabledKey) == NSControlStateValueOff)
        [self emit:@{SPDFMacAIPythonEnabledKey : @YES}];
    if (self.actionHandler) self.actionHandler(SPDFMacAIPythonInstallAction);
}
- (void)refreshAICapabilities:(NSDictionary*)changes {
    for (NSString* key in @[SPDFMacAIWebSearchEnabledKey, SPDFMacAISubagentsEnabledKey])
        if (changes[key]) [(NSButton*)self.controls[key] setState:SwitchState(self.state, key)];
    NSArray* pythonKeys = @[SPDFMacAIPythonEnabledKey, SPDFMacAIPythonStatusKey, SPDFMacAIPythonLocationKey,
                            SPDFMacAIPythonDownloadKey, SPDFMacAIPythonDetailKey];
    for (NSString* key in pythonKeys)
        if (changes[key]) { [self refreshPython]; return; }
}
@end
