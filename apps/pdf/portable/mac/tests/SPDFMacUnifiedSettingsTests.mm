#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "../SPDFMacUnifiedSettings.h"
#import "../SPDFMacSearchablePicker.h"
@interface SPDFMacSearchablePicker (Probe)
- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command;
@end
static int failures;
static NSEvent* pendingMouseUp;
@interface NSWindow (SettingsProbe)
@end
@implementation NSWindow (SettingsProbe)
- (NSEvent*)settingsProbeNextEventMatchingMask:(NSEventMask)mask {
    (void)mask; NSEvent* event=pendingMouseUp; pendingMouseUp=nil; return event;
}
@end
static void Check(BOOL ok,NSString* name) { if(!ok) { failures++; fprintf(stderr,"FAIL %s\n",name.UTF8String); } }
static NSView* Find(NSView* view,NSString* identifier) {
    if([view.identifier isEqual:identifier]) return view;
    for(NSView* child in view.subviews) { NSView* found=Find(child,identifier); if(found) return found; }
    return nil;
}
static void Inspect(NSView* view) {
    if([view isKindOfClass:NSButton.class] && !view.hidden) {
        NSView* ancestor=view.superview;
        while(ancestor && ![ancestor isKindOfClass:NSSearchField.class]) ancestor=ancestor.superview;
        // AppKit's internal search glyph has a 16×15 drawing frame; the enclosing
        // native field owns its tracking. Check our field rather than its private glyph.
        if(ancestor) Check(NSHeight(ancestor.frame)>=28,@"native search field has full-height tracking");
        else Check(NSWidth(view.frame)>15 && NSHeight(view.frame)>15,[@"button has a real target " stringByAppendingString:view.identifier ?: @""]);
        if([NSStringFromClass(view.class) isEqual:@"SPDFSettingsButton"] || [view isKindOfClass:SPDFMacSearchablePicker.class]) {
            NSView* root=view.window.contentView;
            for(NSValue* point in @[[NSValue valueWithPoint:NSMakePoint(2,2)],
                [NSValue valueWithPoint:NSMakePoint(NSWidth(view.bounds)-2,NSHeight(view.bounds)-2)]]) {
                if(!NSPointInRect(point.pointValue,view.visibleRect)) continue;
                NSPoint windowPoint=[view convertPoint:point.pointValue toView:nil];
                Check([root hitTest:[root.superview convertPoint:windowPoint fromView:nil]]==view,
                    [@"settings action visible corners are unobstructed: " stringByAppendingString:view.identifier]);
            }
        }
    }
    for(NSView* child in view.subviews) Inspect(child);
}
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    Check(SPDFUnifiedSettingsShouldPresent(@{},YES,NO),@"existing readers get discovery once");
    Check(!SPDFUnifiedSettingsShouldPresent(@{},NO,NO),@"restored process skips setup");
    Check(!SPDFUnifiedSettingsShouldPresent(@{},YES,YES),@"detached process skips setup");
    NSDictionary* complete=@{@"settingsExperienceVersion":@(SPDFUnifiedSettingsExperienceVersion)};
    Check(!SPDFUnifiedSettingsShouldPresent(complete,YES,NO),@"complete experience does not repeat");
    Check(!SPDFUnifiedSettingsShouldPresent(@{@"settingsExperienceVersion":@(SPDFUnifiedSettingsExperienceVersion),@"showSettingsOnLaunch":@YES},YES,NO),@"completed wizard does not reopen legacy settings prompt");
    SPDFMacUnifiedSettingsController* controller=[[SPDFMacUnifiedSettingsController alloc]
        initWithState:@{@"collectionEnabled":@YES,@"aiEnabled":@NO,@"autoAnalyze":@NO}];
    __block NSDictionary* change; __block NSString* action; __block NSString* credential;
    controller.settingsChanged=^(NSDictionary* value){change=value;};
    controller.actionHandler=^(NSString* value){action=value;};
    controller.credentialHandler=^(NSString* value){credential=value;};
    for(NSValue* size in @[[NSValue valueWithSize:NSMakeSize(760,612)],[NSValue valueWithSize:NSMakeSize(650,520)]]) {
        [controller.window setContentSize:size.sizeValue];
        for(NSString* section in @[@"overview",@"ai",@"collection",@"reading"]) {
            [controller selectSection:section]; [controller.window.contentView layoutSubtreeIfNeeded];
            Inspect(controller.window.contentView);
            NSView* content=[controller valueForKey:@"content"];
            Check(NSWidth(content.bounds)>500,@"scroll content uses available width");
            for(NSView* child in [(NSStackView*)content arrangedSubviews]) {
                NSRect alignment=[child alignmentRectForFrame:child.frame];
                Check(NSMaxX(alignment)<=NSWidth(content.bounds)+1,@"content does not overflow horizontally");
            }
            if(size.sizeValue.width==760) {
                for(NSString* appearance in @[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]) {
                    controller.window.appearance=[NSAppearance appearanceNamed:appearance];
                    NSBitmapImageRep* rep=[controller.window.contentView bitmapImageRepForCachingDisplayInRect:controller.window.contentView.bounds];
                    [controller.window.contentView cacheDisplayInRect:controller.window.contentView.bounds toBitmapImageRep:rep];
                    NSString* path=[NSString stringWithFormat:@"/tmp/sz-settings-%@-%@.png",section,appearance];
                    Check([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],@"native settings preview renders");
                }
            }
        }
    }
    [controller selectSection:@"overview"];
    [(NSButton*)Find(controller.window.contentView,@"showDefaults") performClick:nil];
    Check(Find(controller.window.contentView,@"defaultReader:pdf") && Find(controller.window.contentView,@"defaultReader:epub") && Find(controller.window.contentView,@"defaultReader:md"),@"per-format default reader choices remain available in ordinary Settings");
    [controller selectSection:@"ai"];
    SPDFMacSearchablePicker* language=(id)Find(controller.window.contentView,@"aiLanguage");
    Check([language isKindOfClass:SPDFMacSearchablePicker.class] && language.choices.count>4,@"AI language uses the shared searchable dropdown");
    Check([language.selectedID isEqual:@"en"] && [language.itemName isEqual:@"languages"],@"language picker has clear labels and a default");
    language.selected(@"fr");Check([change[@"aiLanguage"] isEqual:@"fr"],@"language selection is persisted through the settings callback");
    [controller updateState:@{@"aiLanguage":@"ja"}];
    Check([language.selectedID isEqual:@"ja"],@"language updates without rebuilding settings or losing focus");
    SPDFMacSearchablePicker* model=(id)Find(controller.window.contentView,@"model");
    Check([model isKindOfClass:SPDFMacSearchablePicker.class],@"model choice is searchable dropdown, not text input");
    action=nil; [controller updateState:@{@"models":@[@{@"id":@"test/model",@"name":@"Test model"}]}];
    Check(action==nil,@"rendering settings never requests network catalogue");
    model.opened(); Check([action isEqual:@"requestModels"],@"catalogue requested only on explicit open");
    model.selected(@"test/model"); Check([change[@"model"] isEqual:@"test/model"],@"model choice persists exact identifier");
    SPDFMacSearchablePicker* filterProbe=[[SPDFMacSearchablePicker alloc] initWithFrame:NSMakeRect(0,0,300,28)];
    filterProbe.choices=@[@{@"id":@"one/alpha",@"name":@"Alpha"},@{@"id":@"two/beta",@"name":@"Beta"},@{@"id":@"three/beta",@"name":@"Beta 2"}];
    NSSearchField* query=[NSSearchField new]; NSTableView* table=[NSTableView new];
    table.dataSource=(id<NSTableViewDataSource>)filterProbe; [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"model"]];
    [filterProbe setValue:query forKey:@"search"]; [filterProbe setValue:table forKey:@"table"];
    filterProbe.choices=language.choices; query.stringValue=@"français";[filterProbe refreshChoices];
    Check([[[filterProbe valueForKey:@"filtered"] firstObject][@"id"] isEqual:@"fr"],@"language list searches native names");
    query.stringValue=@"Japanese";[filterProbe refreshChoices];
    Check([[[filterProbe valueForKey:@"filtered"] firstObject][@"id"] isEqual:@"ja"],@"language list searches English names");
    filterProbe.choices=@[@{@"id":@"one/alpha",@"name":@"Alpha"},@{@"id":@"two/beta",@"name":@"Beta"},@{@"id":@"three/beta",@"name":@"Beta 2"}];
    query.stringValue=@"BETA"; [filterProbe refreshChoices];
    Check([[filterProbe valueForKey:@"filtered"] count]==2,@"model dropdown filters names case-insensitively");
    [filterProbe control:query textView:nil doCommandBySelector:@selector(moveDown:)];
    __block NSString* selected; filterProbe.selected=^(NSString* value){selected=value;};
    [filterProbe control:query textView:nil doCommandBySelector:@selector(insertNewline:)];
    Check([selected isEqual:@"three/beta"],@"model dropdown arrows and Return choose exact model");
    query.stringValue=@"one/"; [filterProbe refreshChoices];
    Check([[filterProbe valueForKey:@"filtered"] count]==1,@"model dropdown searches provider IDs");
    query.stringValue=@""; filterProbe.selectedID=@"three/beta"; [filterProbe refreshChoices];
    selected=nil; [filterProbe control:query textView:nil doCommandBySelector:@selector(insertNewline:)];
    Check([selected isEqual:@"three/beta"],@"opening model list and pressing Return preserves the current choice");
    Check([filterProbe control:query textView:nil doCommandBySelector:@selector(cancelOperation:)],@"Escape dismisses model dropdown without committing");
    filterProbe.choices=@[]; query.stringValue=@"typed while loading";
    for(NSString* message in @[@"Loading models…",@"Could not load models. Open the list to retry."]) {
        filterProbe.emptyMessage=message; [filterProbe refreshChoices];
        NSTextField* feedback=(id)[(id<NSTableViewDelegate>)filterProbe tableView:table viewForTableColumn:table.tableColumns.firstObject row:0];
        Check([feedback.stringValue isEqual:message],@"typed model query preserves loading and failure feedback");
    }
    Check(Find(controller.window.contentView,@"saveCredential")==nil,@"API key alternative is initially hidden");
    [(NSButton*)Find(controller.window.contentView,@"revealKey") performClick:nil];
    NSSecureTextField* editingKey=[controller valueForKey:@"secret"];
    editingKey.stringValue=@"local-test-draft"; [controller.window makeFirstResponder:editingKey]; [editingKey selectText:nil];
    NSTextView* keyEditor=(NSTextView*)editingKey.currentEditor; keyEditor.selectedRange=NSMakeRange(2,4);
    [controller updateState:@{@"modelStatus":@"Price refreshed",@"connectionStatus":@"Browser sign-in is available"}];
    Check([controller valueForKey:@"secret"]==editingKey && editingKey.currentEditor==keyEditor &&
        [editingKey.stringValue isEqual:@"local-test-draft"] && NSEqualRanges(keyEditor.selectedRange,NSMakeRange(2,4)),
        @"asynchronous status preserves secure draft, selection and focus");
    [controller.window makeFirstResponder:nil];
    [(NSButton*)Find(controller.window.contentView,@"hideKey") performClick:nil];
    NSButton* connect=(NSButton*)Find(controller.window.contentView,@"connect");
    Method original=class_getInstanceMethod(NSWindow.class,@selector(nextEventMatchingMask:));
    Method injected=class_getInstanceMethod(NSWindow.class,@selector(settingsProbeNextEventMatchingMask:));
    method_exchangeImplementations(original,injected);
    for(NSValue* value in @[[NSValue valueWithPoint:NSMakePoint(2,2)],
        [NSValue valueWithPoint:NSMakePoint(NSWidth(connect.bounds)-2,NSHeight(connect.bounds)-2)],
        [NSValue valueWithPoint:NSMakePoint(NSMidX(connect.bounds),NSMidY(connect.bounds))]]) {
        NSPoint point=[connect convertPoint:value.pointValue toView:nil];
        NSView* root=controller.window.contentView;
        NSView* hit=[root hitTest:[root.superview convertPoint:point fromView:nil]];
        Check(hit==connect,@"production Settings hierarchy preserves every action target");
        NSTimeInterval stamp=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0
            timestamp:stamp windowNumber:controller.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        NSEvent* up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
            timestamp:stamp+.01 windowNumber:controller.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
        action=nil; pendingMouseUp=up; [hit mouseDown:down];
        Check([action isEqual:@"connect"],@"full-bounds native click reaches connect on first press");
    }
    SPDFMacSearchablePicker* clickPicker=(id)Find(controller.window.contentView,@"model");
    id pickerTarget=clickPicker.target; SEL pickerAction=clickPicker.action;
    clickPicker.target=controller; clickPicker.action=NSSelectorFromString(@"performAction:");
    clickPicker.identifier=@"pickerTargetProbe";
    for(NSValue* value in @[[NSValue valueWithPoint:NSMakePoint(2,2)],[NSValue valueWithPoint:NSMakePoint(NSWidth(clickPicker.bounds)-2,NSHeight(clickPicker.bounds)-2)]]) {
        NSPoint point=[clickPicker convertPoint:value.pointValue toView:nil];
        NSView* root=controller.window.contentView;
        Check([root hitTest:[root.superview convertPoint:point fromView:nil]]==clickPicker,@"model dropdown full bounds are unobstructed");
        NSTimeInterval stamp=NSProcessInfo.processInfo.systemUptime;
        NSEvent* down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:stamp windowNumber:controller.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        pendingMouseUp=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:stamp+.01 windowNumber:controller.window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
        action=nil; [clickPicker mouseDown:down];
        Check([action isEqual:@"pickerTargetProbe"],@"model dropdown first press fires across its full bounds");
    }
    clickPicker.identifier=@"model"; clickPicker.target=pickerTarget; clickPicker.action=pickerAction;
    method_exchangeImplementations(original,injected);

    NSButton* autoAnalyze=(NSButton*)Find(controller.window.contentView,@"autoAnalyze"); [autoAnalyze performClick:nil];
    Check([change[@"autoAnalyze"] boolValue],@"automatic analysis is separate explicit preference");
    [(NSButton*)Find(controller.window.contentView,@"revealKey") performClick:nil];
    NSSecureTextField* secret=[controller valueForKey:@"secret"]; secret.stringValue=@"test-only-not-a-key";
    [(NSButton*)Find(controller.window.contentView,@"saveCredential") performClick:nil];
    Check([credential isEqual:@"test-only-not-a-key"] && !secret.stringValue.length,@"key delivered separately and immediately cleared");
    Check(![change.allValues containsObject:credential],@"credential never enters preference changes");
    secret.stringValue=@"keyboard-test-only";
    Check(secret.target==controller && secret.action==NSSelectorFromString(@"saveCredential:"),@"Return in key field routes to Use key, not Start reading");
    [NSApp sendAction:secret.action to:secret.target from:secret];
    Check([credential isEqual:@"keyboard-test-only"] && !secret.stringValue.length,@"key Return action consumes only the credential draft");
    // A browser sign-up can lose its way back to the app: the button must never strand the reader.
    [controller updateState:@{@"connecting":@YES,@"connectionStatus":@"Finish connecting in your browser."}];
    NSButton* pending=(NSButton*)Find(controller.window.contentView,@"connect");
    Check(pending.isEnabled && [pending.title isEqual:@"Connect OpenRouter"],
        @"connect stays clickable while the browser sign-in is pending");
    action=nil; [pending performClick:nil];
    Check([action isEqual:@"connect"],@"clicking again while pending starts the sign-in over");
    [controller selectSection:@"ai"];
    Check([(NSButton*)Find(controller.window.contentView,@"connect") isEnabled],
        @"a rebuilt AI section keeps connect clickable while pending");
    [controller updateState:@{@"connecting":@NO,@"connected":@YES}];
    Check(Find(controller.window.contentView,@"disconnect")!=nil,@"connected account exposes disconnect");
    Check(Find(controller.window.contentView,@"saveCredential")==nil && [controller valueForKey:@"secret"]==nil,@"completed key connection removes credential entry controls");
    [controller updateState:@{@"connected":@NO}];
    Check(Find(controller.window.contentView,@"revealKey")!=nil,@"disconnect immediately restores the API-key alternative");
    [controller windowWillClose:[NSNotification notificationWithName:NSWindowWillCloseNotification object:controller.window]];
    Check([action isEqual:@"dismissed"],@"closing Settings never implies Collection consent");
    SPDFMacUnifiedSettingsController* wizard=[[SPDFMacUnifiedSettingsController alloc] initWithState:@{@"setupWizard":@YES,@"wizardStep":@0}];
    __block NSString* wizardAction; __block NSDictionary* wizardChange;
    wizard.actionHandler=^(NSString* value){ wizardAction=value; };
    wizard.settingsChanged=^(NSDictionary* value){ wizardChange=value; };
    for(NSInteger step=0;step<4;step++) {
        [wizard setValue:@(step) forKey:@"wizardStep"]; [wizard showSetupWizard]; [wizard.window.contentView layoutSubtreeIfNeeded];
        if(step==2) Check([Find(wizard.window.contentView,@"aiLanguage") isKindOfClass:SPDFMacSearchablePicker.class],@"setup wizard exposes the same language selector");
        Check(NSHeight(wizard.window.contentView.bounds)==520,@"all wizard steps retain the compact window height");
        NSButton* next=(id)Find(wizard.window.contentView,@"done");
        Check([next.accessibilityLabel isEqual:(step<3 ? @"Continue" : @"Done")],@"wizard footer accessibility label follows the current action");
        NSStackView* wizardContent=[wizard valueForKey:@"content"];
        NSRect scrollFrame=wizardContent.enclosingScrollView.frame;
        Check(fabs(NSHeight(wizard.window.contentView.bounds)-NSMaxY(scrollFrame)-24)<1,@"wizard removes hidden-navigation top space");
        Inspect(wizard.window.contentView);
        NSBitmapImageRep* rep=[wizard.window.contentView bitmapImageRepForCachingDisplayInRect:wizard.window.contentView.bounds];
        [wizard.window.contentView cacheDisplayInRect:wizard.window.contentView.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"/tmp/sz-wizard-%ld.png",(long)step] atomically:YES];
    }
    [wizard.window setContentSize:NSMakeSize(650,478)];
    wizard.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    for(NSInteger step=0;step<4;step++) {
        [wizard setValue:@(step) forKey:@"wizardStep"]; [wizard showSetupWizard]; [wizard.window.contentView layoutSubtreeIfNeeded];
        Inspect(wizard.window.contentView);
        NSView* root=wizard.window.contentView;
        NSBitmapImageRep* rep=[root bitmapImageRepForCachingDisplayInRect:root.bounds]; [root cacheDisplayInRect:root.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"/tmp/sz-wizard-loop2-narrow-%ld.png",(long)step] atomically:YES];
    }
    [wizard setValue:@0 forKey:@"wizardStep"]; [wizard showSetupWizard];
    Check(Find(wizard.window.contentView,@"fullDiskAccess")!=nil,@"wizard begins with Full Disk Access");
    Check(Find(wizard.window.contentView,@"accessibility")==nil,@"no Accessibility prompt");
    [(NSButton*)Find(wizard.window.contentView,@"done") performClick:nil];
    Check(wizard.wizardStep==1 && [wizardChange[@"wizardStep"] integerValue]==1,@"step transitions persist");
    NSSlider* percent=(id)Find(wizard.window.contentView,@"collectionDynamicPercent");
    Check(percent.minValue==50 && percent.maxValue==80 && percent.integerValue==80 && !percent.continuous,@"dynamic percentage defaults to 80 within 50–80 and saves on release");
    for(NSNumber* value in @[@50,@65,@80]) {
        percent.integerValue=value.integerValue; [NSApp sendAction:percent.action to:percent.target from:percent];
        Check([wizardChange[@"collectionDynamicPercent"] isEqual:value],@"dynamic percentage change reaches persistence");
        Check([[(NSTextField*)Find(wizard.window.contentView,@"collectionDynamicPercentLabel") stringValue] isEqual:[value.stringValue stringByAppendingString:@"%"]],@"percentage label follows selected value");
    }
    [wizard updateState:@{@"collectionDynamicPercent":@60}];
    Check(percent.integerValue==60 && [[(NSTextField*)Find(wizard.window.contentView,@"collectionDynamicPercentLabel") stringValue] isEqual:@"60%"],@"persisted percentage updates the existing controls");
    Check([[(NSButton*)Find(wizard.window.contentView,@"setCollectionLocation") title] isEqual:@"Move location…"],@"location action describes moving files");
    Check(Find(wizard.window.contentView,@"collectionStorageGiB")==nil,@"dynamic mode has no static-limit field");
    NSPopUpButton* storage=(id)Find(wizard.window.contentView,@"collectionStorageMode");
    [storage selectItemAtIndex:1]; [NSApp sendAction:storage.action to:storage.target from:storage];
    Check([wizardChange[@"collectionStorageMode"] isEqual:@"static"] && [wizardChange[@"collectionStorageGiB"] doubleValue]>0,@"static selection persists a positive initial budget atomically");
    Check([(NSTextField*)Find(wizard.window.contentView,@"collectionStorageGiB") doubleValue]>0,@"static amount matches a positive actual limit");
    NSTextField* limit=(id)Find(wizard.window.contentView,@"collectionStorageGiB"); double priorLimit=limit.doubleValue;
    for(NSString* invalid in @[@"",@"oops",@"10oops",@"-5",@"0",@"nan",@"1000001"]) {
        wizardChange=nil; limit.stringValue=invalid; [NSApp sendAction:limit.action to:limit.target from:limit];
        Check(wizardChange==nil && limit.doubleValue==priorLimit,@"invalid storage input never changes the saved budget");
        Check(!Find(wizard.window.contentView,@"storageValidation").hidden,@"invalid storage input explains the unchanged limit");
    }
    limit.stringValue=@"12.5"; [NSApp sendAction:limit.action to:limit.target from:limit];
    Check([wizardChange[@"collectionStorageGiB"] doubleValue]==12.5 && Find(wizard.window.contentView,@"storageValidation").hidden,@"valid storage input saves and clears validation");
    [wizard updateState:@{@"collectionBudgetText":@"Moving Collection…",@"collectionLocation":@"/Volumes/Archive/Collection"}];
    Check([[(NSTextField*)Find(wizard.window.contentView,@"collectionBudgetText") stringValue] isEqual:@"Moving Collection…"],@"relocation progress refreshes in place");
    Check([[(NSTextField*)Find(wizard.window.contentView,@"collectionLocation") stringValue] isEqual:@"/Volumes/Archive/Collection"],@"relocation destination refreshes in place");
    [(NSButton*)Find(wizard.window.contentView,@"done") performClick:nil];
    Check(Find(wizard.window.contentView,@"autoAnalyze")==nil && Find(wizard.window.contentView,@"aiEnabled")==nil,@"wizard contains connection and model only");
    NSTextField* disclosure=(id)Find(wizard.window.contentView,@"aiUploadDisclosure");
    Check([disclosure.stringValue containsString:@"sent to OpenRouter"] && [disclosure.stringValue containsString:@"credits"] && !disclosure.hidden,
        @"wizard discloses default automatic upload and account credits before completion");
    [(NSButton*)Find(wizard.window.contentView,@"connect") performClick:nil];
    Check([wizardAction isEqual:@"connect"],@"wizard connect directly invokes browser action");
    [(NSButton*)Find(wizard.window.contentView,@"done") performClick:nil];
    Check(Find(wizard.window.contentView,@"defaultReader:pdf")!=nil && Find(wizard.window.contentView,@"defaultReader:epub")!=nil,@"defaults are separate per format");
    [(NSButton*)Find(wizard.window.contentView,@"defaultReader:epub") performClick:nil];
    Check([wizardAction isEqual:@"defaultReader:epub"],@"default format routes independently");
    NSSearchField* formats=(id)Find(wizard.window.contentView,@"formatSearch"); formats.stringValue=@"unknown format";
    [wizard controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:formats]];
    Check(Find(wizard.window.contentView,@"noMatchingFormats")!=nil,@"unmatched file-type search gives explicit feedback");
    formats.stringValue=@".pdf"; [wizard controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:formats]];
    Check(Find(wizard.window.contentView,@"defaultReader:pdf")!=nil && Find(wizard.window.contentView,@"noMatchingFormats")==nil,@"file-type search accepts a dotted extension");
    [(NSButton*)Find(wizard.window.contentView,@"done") performClick:nil];
    Check([wizardAction isEqual:@"wizardDone"] && !wizard.window.visible,@"wizard Done closes instead of opening settings");
    SPDFMacUnifiedSettingsController* reentrant=[[SPDFMacUnifiedSettingsController alloc]
        initWithState:@{@"setupWizard":@YES,@"wizardStep":@1,@"collectionStorageMode":@"static",@"collectionStorageGiB":@10}];
    __weak SPDFMacUnifiedSettingsController* weakReentrant=reentrant;
    reentrant.settingsChanged=^(NSDictionary* value) {
        [weakReentrant updateState:value];
        // The real host can process Continue during synchronous persistence/status work.
        if(value[@"collectionStorageMode"]) [(NSButton*)Find(weakReentrant.window.contentView,@"done") performClick:nil];
    };
    NSPopUpButton* reentrantMode=(id)Find(reentrant.window.contentView,@"collectionStorageMode");
    [reentrantMode selectItemAtIndex:0]; [NSApp sendAction:reentrantMode.action to:reentrantMode.target from:reentrantMode];
    Check(reentrant.wizardStep==2 && Find(reentrant.window.contentView,@"model")!=nil &&
        Find(reentrant.window.contentView,@"collectionStorageMode")==nil,@"storage callback cannot repaint Collection after Continue advances to AI");
    Check(!controller.window.visible,@"verification never shows a window");
    fprintf(stderr,"Unified settings: %d failures\n",failures); return failures?1:0;
} }
