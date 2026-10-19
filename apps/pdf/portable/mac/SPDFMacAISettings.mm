#import "SPDFMacAISettings.h"
#import "SPDFMacAILanguage.h"
#import "SPDFMacAITransport.h"
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
@implementation SPDFMacAISettingsSnapshot
- (instancetype)initWithSettings:(SPDFMacAISettings*)settings {
    if (!(self = [super init])) return nil;
    _model = [settings.model copy] ?: SPDFMacAIDefaultModel;
    _language = [settings.language copy] ?: @"en";
    _aiWebSearchEnabled = settings.aiWebSearchEnabled;
    _aiPythonEnabled = settings.aiPythonEnabled;
    _aiSubagentsEnabled = settings.aiSubagentsEnabled;
    return self;
}
@end
// The capability switches, written by -save: and read by -load: in the same flat true/false form as the others.
static NSArray<NSArray<NSString*>*>* CapabilityKeys(void) {
    return @[@[@"web_search_enabled", @"aiWebSearchEnabled"], @[@"python_enabled", @"aiPythonEnabled"],
             @[@"subagents_enabled", @"aiSubagentsEnabled"]];
}
@implementation SPDFMacAISettings { NSURL* _URL; NSDictionary* _baseline; }
- (SPDFMacAISettingsSnapshot*)snapshot { return [[SPDFMacAISettingsSnapshot alloc] initWithSettings:self]; }
+ (NSURL*)defaultURL {
    NSString* root=NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
    if(!root.length)root=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ShenzhenPDF"];
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"ai-settings.yaml"]];
}
- (instancetype)initWithURL:(NSURL*)URL {
    if((self=[super init])) {
        _URL=URL; _model=SPDFMacAIDefaultModel; _language=@"en"; _enabled=YES; _automaticAnalysis=YES;
        _aiWebSearchEnabled=YES; _aiPythonEnabled=YES; _aiSubagentsEnabled=YES; _baseline=[self values];
    }
    return self;
}
- (BOOL)allowsRequestsForSetupRevision:(NSInteger)revision {
    return self.enabled && self.connectionConfigured && self.onboardingRevision>=revision;
}
- (NSDictionary*)values {
    NSMutableDictionary* values=[@{@"model":self.model ?: SPDFMacAIDefaultModel,@"enabled":@(self.enabled),
        @"language":self.language ?: @"en",@"connection_configured":@(self.connectionConfigured),
        @"automatic_analysis":@(self.automaticAnalysis),@"show_settings_on_launch":@(self.showSettingsOnLaunch),
        @"onboarding_revision":@(self.onboardingRevision),@"onboarding_step":@(self.onboardingStep),
        @"model_context_tokens":@(self.modelContextTokens)} mutableCopy];
    for(NSArray* key in CapabilityKeys()) values[key[0]]=@([[self valueForKey:key[1]] boolValue]);
    return values;
}
- (BOOL)load:(NSError**)error {
    if(error)*error=nil;
    if(![NSFileManager.defaultManager fileExistsAtPath:_URL.path])return YES;
    NSDictionary* attrs=[NSFileManager.defaultManager attributesOfItemAtPath:_URL.path error:error];
    if(!attrs || [attrs[NSFileSize] unsignedLongLongValue]>8192) {
        if(error && !*error)*error=SPDFMacAIError(30,@"AI settings are too large to read."); return NO;
    }
    NSString* YAML=[NSString stringWithContentsOfURL:_URL encoding:NSUTF8StringEncoding error:error];
    if(!YAML)return NO;
    // A flat, deliberately restricted YAML scalar schema: secrets and arbitrary objects cannot enter this file.
    for(NSString* line in [YAML componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange colon=[line rangeOfString:@":"]; if(colon.location==NSNotFound)continue;
        NSString* key=[[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString* value=[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([key isEqual:@"model"] && value.length>0 && value.length<=160 &&
            [value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.:~"].invertedSet].location==NSNotFound)
            self.model=value;
        else if([key isEqual:@"language"] && SPDFMacAILanguageNames()[value])self.language=value;
        else if([key isEqual:@"connection_configured"])self.connectionConfigured=[value isEqual:@"true"];
        else if([key isEqual:@"enabled"])self.enabled=[value isEqual:@"true"];
        else if([key isEqual:@"automatic_analysis"])self.automaticAnalysis=[value isEqual:@"true"];
        else if([key isEqual:@"show_settings_on_launch"])self.showSettingsOnLaunch=[value isEqual:@"true"];
        else if([key isEqual:@"onboarding_step"])self.onboardingStep=MIN(3,MAX(0,value.integerValue));
        else if([key isEqual:@"onboarding_revision"])self.onboardingRevision=MAX(0,value.integerValue);
        else if([key isEqual:@"model_context_tokens"])
            self.modelContextTokens=(NSUInteger)MIN(100000000LL,MAX(0LL,value.longLongValue));
        else for(NSArray* capability in CapabilityKeys())
            if([key isEqual:capability[0]])[self setValue:@([value isEqual:@"true"]) forKey:capability[1]];
    }
    _baseline=[self values]; return YES;
}
- (BOOL)save:(NSError**)error {
    if(error)*error=nil;
    if(!self.language || !SPDFMacAILanguageNames()[self.language]) {
        if(error)*error=SPDFMacAIError(31,@"Choose an AI language from the list."); return NO;
    }
    if(!self.model.length || self.model.length>160 || [self.model rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.:~"].invertedSet].location!=NSNotFound) {
        if(error)*error=SPDFMacAIError(31,@"Enter a valid OpenRouter model identifier."); return NO;
    }
    if(![NSFileManager.defaultManager createDirectoryAtURL:_URL.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
    NSString* lockPath=[_URL.path stringByAppendingString:@".lock"];
    int descriptor=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(descriptor<0 || flock(descriptor,LOCK_EX)!=0) {
        if(descriptor>=0)close(descriptor);
        if(error)*error=SPDFMacAIError(32,@"AI settings could not be locked for saving."); return NO;
    }
    SPDFMacAISettings* current=[[SPDFMacAISettings alloc] initWithURL:_URL];
    if(![current load:error]) { flock(descriptor,LOCK_UN);close(descriptor);return NO; }
    NSMutableDictionary* merged=[[current values] mutableCopy]; NSDictionary* requested=[self values];
    // Independent windows update only their changed fields, preserving other windows' settings.
    for(NSString* key in requested)if(![requested[key] isEqual:_baseline[key]])merged[key]=requested[key];
    // A context window describes one model: it travels with that model and never lands on another window's choice.
    NSString* context=@"model_context_tokens";
    if(![merged[@"model"] isEqual:requested[@"model"]]) merged[context]=[current values][context];
    else if(![requested[@"model"] isEqual:_baseline[@"model"]]) merged[context]=requested[context];
    NSString* YAML=[NSString stringWithFormat:@"schema_version: 1\nmodel: %@\nlanguage: %@\nenabled: %@\nconnection_configured: %@\nautomatic_analysis: %@\nshow_settings_on_launch: %@\nonboarding_revision: %ld\nonboarding_step: %ld\n"
        "model_context_tokens: %lu\n",
        merged[@"model"],merged[@"language"],[merged[@"enabled"] boolValue] ? @"true" : @"false",
        [merged[@"connection_configured"] boolValue] ? @"true" : @"false",
        [merged[@"automatic_analysis"] boolValue] ? @"true" : @"false",
        [merged[@"show_settings_on_launch"] boolValue] ? @"true" : @"false",[merged[@"onboarding_revision"] longValue],
        [merged[@"onboarding_step"] longValue],(unsigned long)[merged[@"model_context_tokens"] unsignedIntegerValue]];
    for(NSArray* capability in CapabilityKeys())
        YAML=[YAML stringByAppendingFormat:@"%@: %@\n",capability[0],
            [merged[capability[0]] boolValue] ? @"true" : @"false"];
    BOOL saved=[[YAML dataUsingEncoding:NSUTF8StringEncoding] writeToURL:_URL options:NSDataWritingAtomic error:error];
    if(saved) {
        chmod(_URL.fileSystemRepresentation,0600); self.model=merged[@"model"]; self.language=merged[@"language"]; self.enabled=[merged[@"enabled"] boolValue];
        self.connectionConfigured=[merged[@"connection_configured"] boolValue];
        self.automaticAnalysis=[merged[@"automatic_analysis"] boolValue];
        self.showSettingsOnLaunch=[merged[@"show_settings_on_launch"] boolValue];
        self.onboardingRevision=[merged[@"onboarding_revision"] integerValue];
        self.onboardingStep=[merged[@"onboarding_step"] integerValue];
        self.modelContextTokens=[merged[@"model_context_tokens"] unsignedIntegerValue];
        for(NSArray* capability in CapabilityKeys())[self setValue:merged[capability[0]] forKey:capability[1]];
        _baseline=[self values];
    }
    flock(descriptor,LOCK_UN);close(descriptor);return saved;
}
@end
