#import "SPDFMacAIIntegration.h"
#import "SPDFMacUnifiedSettings.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAICapabilitiesSettingsIntegration.h"
#import "SPDFMacAICredentials.h"
#import "SPDFMacAIOpenRouterAuth.h"
#import "SPDFMacAIModelCatalog.h"
#import "SPDFMacDefaultFormats.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionIntegration.h"
#import <objc/runtime.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
@interface ShenzhenMacDelegate (AISettingsHost)
- (void)makeDefaultPDFReader:(id)sender;
- (BOOL)hasActiveDocument;
- (void)showUnifiedSettingsMode:(BOOL)wizard;
- (void)requestAIModels;
- (void)openFullDiskAccessSettings;

@end
static char settingsControllerKey, authKey, authGenerationKey, catalogKey, settingsObserverKey, catalogModelsKey, onboardingLockKey;
static char authReturnObserverKey;
static void StopReturnWatch(ShenzhenMacDelegate* reader);
static NSUInteger InvalidateAuth(ShenzhenMacDelegate* reader) {
    NSUInteger generation=[objc_getAssociatedObject(reader,&authGenerationKey) unsignedIntegerValue]+1;
    objc_setAssociatedObject(reader,&authGenerationKey,@(generation),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [objc_getAssociatedObject(reader,&authKey) cancel];
    objc_setAssociatedObject(reader,&authKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    StopReturnWatch(reader);
    return generation;
}
// A sign-up that never returns to the app leaves the button and status pending;
// coming back with nothing received puts them back to idle. The browser page
// still works if they finish it afterwards.
static void WatchForReturnWithoutCallback(ShenzhenMacDelegate* reader,SPDFMacUnifiedSettingsController* controller,
    SPDFMacAIOpenRouterAuth* auth) {
    __weak SPDFMacUnifiedSettingsController* weakController=controller;
    SPDFMacAISignInReturnWatch* watch=[[SPDFMacAISignInReturnWatch alloc] initWithSignIn:auth delay:4 lostWayBack:^{
        [weakController updateState:@{@"connecting":@NO,
            @"connectionStatus":@"Not connected yet. If you finished signing up, click Connect OpenRouter again."}];
    }];
    objc_setAssociatedObject(reader,&authReturnObserverKey,watch,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void StopReturnWatch(ShenzhenMacDelegate* reader) {
    [(SPDFMacAISignInReturnWatch*)objc_getAssociatedObject(reader,&authReturnObserverKey) stop];
    objc_setAssociatedObject(reader,&authReturnObserverKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void ReleaseSetupLock(ShenzhenMacDelegate* reader) {
    NSNumber* lock=objc_getAssociatedObject(reader,&onboardingLockKey);
    if(lock) { flock(lock.intValue,LOCK_UN);close(lock.intValue);objc_setAssociatedObject(reader,&onboardingLockKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}
static SPDFMacAISettings* ReadSettings(void) {
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    [settings load:nil]; return settings;
}
// How much `model` reads at once according to the loaded model list; 0 when not loaded or not stated.
static NSUInteger CatalogContextTokens(ShenzhenMacDelegate* reader,NSString* model) {
    for(NSDictionary* entry in objc_getAssociatedObject(reader,&catalogModelsKey))
        if([entry[@"id"] isEqual:model]) return [entry[@"contextTokens"] unsignedIntegerValue];
    return 0;
}
static void RememberContextTokens(ShenzhenMacDelegate* reader) {
    SPDFMacAISettings* settings=ReadSettings(); NSUInteger tokens=CatalogContextTokens(reader,settings.model);
    if(!tokens || tokens==settings.modelContextTokens) return;
    settings.modelContextTokens=tokens; [settings save:nil];
}
static SPDFMacAISettings* AnalysisSettings(SPDFMacAISettings* settings) {
    // Defaults are on; no file work begins until setup and connection are complete.
    if(![settings allowsRequestsForSetupRevision:SPDFUnifiedSettingsExperienceVersion]) {
        settings.enabled=NO; settings.automaticAnalysis=NO;
    }
    return settings;
}
@implementation ShenzhenMacDelegate (SPDFMacAISettingsIntegration)
- (NSDictionary*)unifiedSettingsState {
    SPDFMacAISettings* ai=ReadSettings(); NSDictionary* collection=SPDFMacCollectionStore.defaultStore.settings;
    BOOL connected=ai.connectionConfigured; // Status display must never read Keychain at launch.
    NSDictionary* budget=[SPDFMacCollectionStore.defaultStore storageBudget];
    NSString* budgetText=[budget[@"storageMode"] isEqual:@"unlimited"] ? @"No storage limit" : [budget[@"capacityAvailable"] boolValue] ?
        [NSString stringWithFormat:@"Current limit: %@",[NSByteCountFormatter stringFromByteCount:[budget[@"storageLimitBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]] : @"Disk capacity unavailable";
    NSMutableDictionary* state=[@{@"wizardStep":@(ai.onboardingStep),@"defaultFormats":SPDFMacDefaultFormatStatus(),
        @"collectionStorageMode":collection[@"storageMode"] ?: @"dynamic",
        @"collectionDynamicPercent":collection[@"storageDynamicPercent"] ?: @80,
        @"collectionStorageGiB":@([collection[@"storageLimitBytes"] doubleValue]/(1024.0*1024*1024)),
        @"collectionBudgetText":budgetText,@"collectionLocation":SPDFMacCollectionStore.defaultStore.rootURL.path ?: @"",
        @"models":objc_getAssociatedObject(self,&catalogModelsKey) ?: @[],@"connected":@(connected),@"model":ai.model,@"aiLanguage":ai.language,@"aiEnabled":@(ai.enabled),
        @"autoAnalyze":@(ai.automaticAnalysis),@"showSettingsOnLaunch":@(ai.showSettingsOnLaunch),
        @"collectionEnabled":@(![collection[@"choice"] isEqual:@"disabled"]),
        @"collectionChoiceMade":@([@[@"enabled",@"disabled"] containsObject:collection[@"choice"] ?: @""]),
        @"showShortcutsOnLaunch":@(_showShortcutHelpOnLaunch),@"keepImageColors":@(_darkThemePreservesImagesDefault)}
        mutableCopy];
    [state addEntriesFromDictionary:[self aiCapabilitiesSettingsState:ai]]; return state;
}
- (void)showUnifiedSettings:(id)sender {
    (void)sender; [self showUnifiedSettingsMode:NO];
}
- (void)showUnifiedSettingsMode:(BOOL)wizard {
    SPDFMacUnifiedSettingsController* controller=objc_getAssociatedObject(self,&settingsControllerKey);
    if (!controller) {
        NSMutableDictionary* state=[[self unifiedSettingsState] mutableCopy]; state[@"setupWizard"]=@(wizard);
        controller=[[SPDFMacUnifiedSettingsController alloc] initWithState:state];
        objc_setAssociatedObject(self,&settingsControllerKey,controller,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak __typeof__(self) weakSelf=self;
        controller.settingsChanged=^(NSDictionary* changes) { [weakSelf applyUnifiedSettings:changes]; };
        controller.actionHandler=^(NSString* action) { [weakSelf unifiedSettingsAction:action]; };
        controller.credentialHandler=^(NSString* secret) {
            NSError* error=nil;
            ShenzhenMacDelegate* reader=weakSelf; if (!reader) return;
            InvalidateAuth(reader);
            BOOL saved=[SPDFMacAICredentials storeAPIKey:secret error:&error];
            SPDFMacUnifiedSettingsController* c=objc_getAssociatedObject(reader,&settingsControllerKey);
            if (saved) [reader applyUnifiedSettings:@{@"connectionConfigured":@YES}];
            [c updateState:[reader unifiedSettingsState]];
            [c updateState:@{@"connecting":@NO,@"connectionStatus":saved ?
                @"Connected." :
                (error.localizedDescription ?: @"The API key could not be saved. Try again.")}];
            if (saved) [reader requestAIModels];
            else if (error) [reader->_window presentError:error];
        };
    } else [controller updateState:[self unifiedSettingsState]];
    if(wizard) [controller showSetupWizard]; else [controller showSettings];
    [controller showForWindow:_window];
}
- (void)showAIConnectionSettingsWithReason:(NSString*)reason {
    [self showUnifiedSettings:nil];
    SPDFMacUnifiedSettingsController* controller=objc_getAssociatedObject(self,&settingsControllerKey);
    [controller updateState:@{@"connectionStatus":reason ?: @""}]; [controller selectSection:@"ai"];
}
- (void)requestAIModels {
    SPDFMacUnifiedSettingsController* controller=objc_getAssociatedObject(self,&settingsControllerKey);
    NSArray* cached=objc_getAssociatedObject(self,&catalogModelsKey);
    if(cached.count) { [controller updateState:@{@"models":cached,@"modelsLoading":@NO}]; return; }
    if(objc_getAssociatedObject(self,&catalogKey))return;
    [controller updateState:@{@"modelsLoading":@YES,@"modelStatus":@"Loading models…"}];
    __weak ShenzhenMacDelegate* weakSelf=self;
    NSURLSessionDataTask* task=SPDFMacAIFetchModels(^(NSArray* models,NSError* error) {
        ShenzhenMacDelegate* reader=weakSelf; if(!reader)return;
        objc_setAssociatedObject(reader,&catalogKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(models) [reader aiModelListDidLoad:models];
        [controller updateState:@{@"models":models ?: @[],@"modelsLoading":@NO,
            @"modelStatus":error ? @"Could not load models. Open the list to retry." : @"Models with Images can inspect page images and diagrams."}];
    });
    objc_setAssociatedObject(self,&catalogKey,task,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)aiModelListLoaded { return objc_getAssociatedObject(self,&catalogModelsKey)!=nil; }
- (void)aiModelListDidLoad:(NSArray<NSDictionary*>*)models {
    objc_setAssociatedObject(self,&catalogModelsKey,[models copy] ?: @[],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RememberContextTokens(self);
}
- (void)applyUnifiedSettings:(NSDictionary*)changes {
    SPDFMacAISettings* ai=ReadSettings();
    if(changes[@"wizardStep"])ai.onboardingStep=MIN(3,MAX(0,[changes[@"wizardStep"] integerValue]));
    if(changes[@"connectionConfigured"])ai.connectionConfigured=[changes[@"connectionConfigured"] boolValue];
    if (changes[@"model"]) { ai.model=changes[@"model"]; ai.modelContextTokens=CatalogContextTokens(self,ai.model); }
    if (changes[@"aiLanguage"]) ai.language=changes[@"aiLanguage"];
    if (changes[@"aiEnabled"]) ai.enabled=[changes[@"aiEnabled"] boolValue];
    if (changes[@"autoAnalyze"]) ai.automaticAnalysis=[changes[@"autoAnalyze"] boolValue];
    if (changes[@"showSettingsOnLaunch"]) ai.showSettingsOnLaunch=[changes[@"showSettingsOnLaunch"] boolValue];
    SPDFMacAICapabilitiesApply(ai,changes);
    NSError* error=nil; [ai save:&error];
    if (!error && changes[@"collectionEnabled"]) {
        [SPDFMacCollectionStore.defaultStore updateSettings:@{@"choice":[changes[@"collectionEnabled"] boolValue] ? @"enabled" : @"disabled"} error:&error];
        if (!error && [changes[@"collectionEnabled"] boolValue])
            for (SPDFDocumentTab* tab in _tabs) [self collectionDidOpenPath:tab.path];
    }
    NSMutableDictionary* storage=[NSMutableDictionary dictionary];
    if(changes[@"collectionStorageMode"]) {
        storage[@"storageMode"]=changes[@"collectionStorageMode"];
    }
    if(changes[@"collectionDynamicPercent"])storage[@"storageDynamicPercent"]=@(MAX(50,MIN(80,[changes[@"collectionDynamicPercent"] integerValue])));
    if(changes[@"collectionStorageGiB"]) {
        double size=[changes[@"collectionStorageGiB"] doubleValue];
        if(!isfinite(size) || size<=0 || size>1000000) {
            error=[NSError errorWithDomain:@"ShenzhenPDF.Collection" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Enter a storage limit greater than zero (up to 1,000,000 GiB)."}];
        } else storage[@"storageLimitBytes"]=@((unsigned long long)(size*1024*1024*1024));
    }
    if([storage[@"storageMode"] isEqual:@"static"] && !storage[@"storageLimitBytes"] &&
        ![SPDFMacCollectionStore.defaultStore.settings[@"storageLimitBytes"] unsignedLongLongValue]) storage[@"storageLimitBytes"]=@(10ULL*1024*1024*1024);
    if(!error && storage.count) {
        [SPDFMacCollectionStore.defaultStore updateSettings:storage error:&error];
        [(SPDFMacUnifiedSettingsController*)objc_getAssociatedObject(self,&settingsControllerKey) updateState:[self unifiedSettingsState]];
    }
    if (changes[@"keepImageColors"]) { _darkThemePreservesImagesDefault=[changes[@"keepImageColors"] boolValue]; [self savePersistentState]; }
    if (changes[@"showShortcutsOnLaunch"]) { _showShortcutHelpOnLaunch=[changes[@"showShortcutsOnLaunch"] boolValue]; [self savePersistentState]; }
    [self configureAIAnalysis:AnalysisSettings(ReadSettings())];
    if (![ai allowsRequestsForSetupRevision:SPDFUnifiedSettingsExperienceVersion]) [self cancelAIChat];
    if (!error) [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"ShenzhenPDFAISettingsChanged" object:nil userInfo:nil deliverImmediately:YES];
    if (error) [_window presentError:error];
}
- (void)unifiedSettingsAction:(NSString*)action {
    SPDFMacUnifiedSettingsController* controller=objc_getAssociatedObject(self,&settingsControllerKey);
    if([@[@"dismissed",@"done"] containsObject:action]) ReleaseSetupLock(self);
    if ([action isEqual:@"dismissed"]) {
        InvalidateAuth(self); [controller updateState:@{@"connecting":@NO,@"connectionStatus":@"Sign in in your browser, or use an API key."}]; return;
    }
    if ([action isEqual:@"done"] || [action isEqual:@"wizardDone"]) {
        InvalidateAuth(self);
        if([action isEqual:@"wizardDone"]) {
            SPDFMacAISettings* settings=ReadSettings(); settings.onboardingRevision=SPDFUnifiedSettingsExperienceVersion;
            settings.onboardingStep=0; settings.showSettingsOnLaunch=NO;
            // Completion is not a credential health check. A noninteractive ACL/lock
            // failure must not erase a connection the user already configured.
            if(!settings.connectionConfigured && [SPDFMacAICredentials APIKeyWithError:nil].length)
                settings.connectionConfigured=YES;
            NSError* error=nil;
            if(![settings save:&error]) { [_window presentError:error]; [self showUnifiedSettingsMode:YES]; return; }
            ReleaseSetupLock(self);
            NSString* choice=SPDFMacCollectionStore.defaultStore.settings[@"choice"];
            if(![@[@"enabled",@"disabled"] containsObject:choice ?: @""]) [self applyUnifiedSettings:@{@"collectionEnabled":@YES}];
            [self configureAIAnalysis:AnalysisSettings(ReadSettings())];
            [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"ShenzhenPDFAISettingsChanged" object:nil userInfo:nil deliverImmediately:YES];
        }
        return;
    }
    if([self performAICapabilitiesSettingsAction:action controller:controller]) return;
    if([action isEqual:@"requestModels"]) { [self requestAIModels]; return; }
    if([action isEqual:@"setCollectionLocation"]) {
        NSOpenPanel* panel=[NSOpenPanel openPanel]; panel.canChooseDirectories=YES; panel.canChooseFiles=NO;
        [panel beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse response) {
            if(response!=NSModalResponseOK)return;
            NSURL* destination=panel.URL;
            [controller updateState:@{@"collectionBudgetText":@"Moving Collection…"}];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                NSError* error=nil; [SPDFMacCollectionStore.defaultStore relocateToURL:destination error:&error];
                dispatch_async(dispatch_get_main_queue(),^{
                    [controller updateState:[self unifiedSettingsState]];
                    if(error)[controller.window presentError:error];
                });
            });
        }]; return;
    }
    if([action hasPrefix:@"defaultReader:"]) {
        NSError* error=nil; SPDFMacMakeDefaultForFormat([action substringFromIndex:14],&error);
        [controller updateState:@{@"defaultFormats":SPDFMacDefaultFormatStatus()}];
        if(error)[controller.window presentError:error]; return;
    }
    if ([action isEqual:@"connect"]) {
        [controller updateState:@{@"connecting":@YES,
            @"connectionStatus":@"Finish connecting in your browser. If that page is gone, click Connect OpenRouter "
                "again."}];
        NSUInteger generation=InvalidateAuth(self);
        SPDFMacAIOpenRouterAuth* auth=[SPDFMacAIOpenRouterAuth new];
        objc_setAssociatedObject(self,&authKey,auth,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak __typeof__(self) weakSelf=self; NSError* error=nil;
        NSURL* URL=[auth startWithCompletion:^(BOOL connected,NSError* problem) {
            __typeof__(self) reader=weakSelf; if (!reader ||
                [objc_getAssociatedObject(reader,&authGenerationKey) unsignedIntegerValue]!=generation) return;
            StopReturnWatch(reader); // finished or cancelled: nothing is pending any more
            if (connected) [reader applyUnifiedSettings:@{@"connectionConfigured":@YES}];
            [controller updateState:[reader unifiedSettingsState]];
            [controller updateState:@{@"connecting":@NO,@"connectionStatus":connected ? @"Connected." :
                problem.code==NSURLErrorCancelled ? @"Connection cancelled. Connect again when you are ready." : @"Connection failed. Try again."}];
            if (problem && problem.code!=NSURLErrorCancelled) [controller.window presentError:problem];
            if (connected) [reader requestAIModels];
        } error:&error];
        if (URL) WatchForReturnWithoutCallback(self,controller,auth);
        if (URL) [NSWorkspace.sharedWorkspace openURL:URL]; else { [controller updateState:@{@"connecting":@NO,@"connectionStatus":error.localizedDescription ?: @"Could not begin browser sign-in. Try again."}]; if (error) [controller.window presentError:error]; }
    } else if ([action isEqual:@"disconnect"]) {
        InvalidateAuth(self); NSError* error=nil;
        [SPDFMacAICredentials removeAPIKeyWithError:&error]; [self applyUnifiedSettings:@{@"connectionConfigured":@NO}];
        [controller updateState:[self unifiedSettingsState]];
        [controller updateState:@{@"connecting":@NO,@"connectionStatus":error ? error.localizedDescription : @"Disconnected. Connect OpenRouter when you want to use AI again."}];
        if (error) [controller.window presentError:error];
    } else if ([action isEqual:@"defaultReader"]) [self makeDefaultPDFReader:nil];
    else if ([action isEqual:@"fullDiskAccess"]) [self openFullDiskAccessSettings];
    else if ([action isEqual:@"shortcuts"]) [self showShortcutHelp:nil];
    else if ([action isEqual:@"collection"]) [self showCollectionManager:nil];
    else if ([action isEqual:@"collectionSettings"]) [self showCollectionSettings:nil];
}
- (void)observeAISettingsChanges {
    if (objc_getAssociatedObject(self,&settingsObserverKey)) return;
    __weak ShenzhenMacDelegate* weakSelf=self;
    id observer=[NSDistributedNotificationCenter.defaultCenter addObserverForName:@"ShenzhenPDFAISettingsChanged"
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* note) {
            (void)note; ShenzhenMacDelegate* reader=weakSelf; if (!reader) return;
            SPDFMacAISettings* settings=ReadSettings(); [reader configureAIAnalysis:AnalysisSettings(settings)];
            if (![settings allowsRequestsForSetupRevision:SPDFUnifiedSettingsExperienceVersion]) [reader cancelAIChat];
        }];
    objc_setAssociatedObject(self,&settingsObserverKey,observer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)showUnifiedSettingsAfterFirstPaint {
    [self observeAISettingsChanges];
    [self friendsAfterFirstPaint];
    SPDFMacAISettings* settings=ReadSettings();
    [self configureAIAnalysis:AnalysisSettings(ReadSettings())];
    if(self.restoreWindowID.length || self.detachedTabLaunch)return;
    if(settings.onboardingRevision>=SPDFUnifiedSettingsExperienceVersion)return;
    NSURL* URL=SPDFMacAISettings.defaultURL;
    [NSFileManager.defaultManager createDirectoryAtURL:URL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    int fd=open([[URL.path stringByAppendingString:@".onboarding.lock"] fileSystemRepresentation],O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(fd<0 || flock(fd,LOCK_EX|LOCK_NB)!=0) { if(fd>=0)close(fd);return; }
    settings=ReadSettings();
    if(settings.onboardingRevision>=SPDFUnifiedSettingsExperienceVersion) { flock(fd,LOCK_UN);close(fd);return; }
    // Completion, not presentation, marks setup done. Hold the process lock until dismissal.
    objc_setAssociatedObject(self,&onboardingLockKey,@(fd),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self showUnifiedSettingsMode:YES];
}
@end
