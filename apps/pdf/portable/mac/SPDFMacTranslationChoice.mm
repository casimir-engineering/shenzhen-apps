#import "SPDFMacTranslationChoice.h"
#import "SPDFMacTranslationEnablement.h"
#import "SPDFMacTranslateLanguagePopover.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacModels.h"
#import "SPDFMacSupport.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacCollectionStore.h"
#import <objc/runtime.h>

static char localRequestKey;

@interface ShenzhenMacDelegate (SPDFMacTranslationChoicePrivate)
- (void)translateDocumentLocally:(id)sender;
- (NSInteger)indexOfTabForPath:(NSString*)path;
- (void)openPath:(NSString*)path;
- (BOOL)pathIsInTemporaryLocation:(NSString*)path;
@end

@implementation ShenzhenMacDelegate (SPDFMacTranslationChoice)
- (void)translateDocument:(id)sender {
    if (!spdf_translation_command_enabled([self translationContext]) || ![self selectedTab].path.length) { NSBeep(); return; }
    // Under the button when it is in the toolbar; from the File or overflow menu, under the toolbar's right end.
    NSView* anchor=_translateButton.window && !_translateButton.hidden && _translateButton.superview ? _translateButton :
        ([sender isKindOfClass:NSView.class] ? sender : _toolbar);
    __weak ShenzhenMacDelegate* weakSelf=self;
    [SPDFMacTranslateLanguagePopover showRelativeToView:anchor localLanguages:spdf_translation_languages()
                                              translate:^(NSString* language, NSString* localCode) {
        if (localCode) [weakSelf translateShownDocumentLocallyInto:localCode language:language];
        else [weakSelf translateShownDocumentInto:language];
    }];
}
- (BOOL)translateShownDocumentInto:(NSString*)language {
    SPDFDocumentTab* tab=[self selectedTab];
    if (!tab.path.length || !language.length) return NO;
    NSString* name=spdf_tab_display_name(tab) ?: tab.title.length ? tab.title : tab.path.lastPathComponent;
    return [self aiSendRequestInNewChat:[NSString stringWithFormat:@"Translate “%@” to %@.",name,language]];
}

#pragma mark On this Mac
- (void)translateShownDocumentLocallyInto:(NSString*)code language:(NSString*)language {
    SPDFDocumentTab* tab=[self selectedTab];
    if (!tab.path.length || !code.length) { NSBeep(); return; }
    NSString* name=spdf_tab_display_name(tab) ?: tab.path.lastPathComponent.stringByDeletingPathExtension;
    objc_setAssociatedObject(self,&localRequestKey,@{@"target":code,@"language":language ?: code,@"name":name ?: @"Document"},
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self translateDocumentLocally:nil];
}
- (NSDictionary*)localTranslationRequest { return objc_getAssociatedObject(self,&localRequestKey); }
- (void)noteLocalTranslationMakesPDF {
    NSMutableDictionary* request=[[self localTranslationRequest] mutableCopy];
    if (!request) return;
    request[@"madePDF"]=@YES;
    objc_setAssociatedObject(self,&localRequestKey,request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)clearLocalTranslationRequest { objc_setAssociatedObject(self,&localRequestKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

// The best guess of a sample's language, as the primary code ("zh" for either Chinese script); nil when unsure.
static NSString* GuessLanguage(NSString* text) {
    if (!text.length) return nil;
    NSString* sample=text.length>6000 ? [text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:6000].location] : text;
    NSString* guess=CFBridgingRelease(CFStringTokenizerCopyBestStringLanguage((__bridge CFStringRef)sample,
                                                                               CFRangeMake(0,(CFIndex)sample.length)));
    return [guess componentsSeparatedByString:@"-"].firstObject.lowercaseString;
}
- (NSString*)localTranslationSourceForText:(NSString*)text target:(NSString*)target {
    NSMutableSet* codes=[NSMutableSet set];
    for (NSDictionary* language in spdf_translation_languages()) if (language[@"code"]) [codes addObject:language[@"code"]];
    NSString* guess=GuessLanguage(text);
    if ([codes containsObject:guess] && ![guess isEqual:target]) return guess;
    // Mostly in the target language (a Chinese datasheet full of English part names, say): the lines in another
    // script are what needs translating, so their language is the one to translate from.
    spdf_translation_script targetScript=spdf_translation_script_for_language(target.UTF8String);
    NSMutableString* others=[NSMutableString string];
    for (NSString* line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
        if (line.length && spdf_translation_should_translate(line.UTF8String,SPDF_TRANSLATION_SCRIPT_UNKNOWN,targetScript)) {
            [others appendString:line]; [others appendString:@"\n"];
        }
    NSString* second=GuessLanguage(others);
    if ([codes containsObject:second] && ![second isEqual:target]) return second;
    if ([guess isEqual:target] && !others.length) return nil;
    // Nothing recognisable: the language translated from last time, as the dialog this replaced remembered it.
    NSString* last=_translationSourceLanguage.length ? _translationSourceLanguage : @"zh";
    if (![last isEqual:target]) return last;
    return [target isEqual:@"en"] ? @"zh" : @"en";
}
- (NSString*)localTranslationDirectory {
    NSString* directory=_path.stringByDeletingLastPathComponent;
    BOOL beside=directory.length && !SPDFMacPathIsCollectionArchive(_path) &&
        ![SPDFMacCollectionStore.defaultStore isArchivePath:_path] &&
        ![self pathIsInTemporaryLocation:_path] && [NSFileManager.defaultManager isWritableFileAtPath:directory];
    if (beside) return directory;
    return [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject.path ?:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
}
- (NSString*)localTranslationOutputPathInDirectory:(NSString*)directory request:(NSDictionary*)request {
    NSString* name=[[request[@"name"] ?: @"Document" stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
        stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* base=[NSString stringWithFormat:@"%@ (%@)",name,request[@"language"] ?: request[@"target"]];
    NSString* candidate=[directory stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"pdf"]];
    for (NSUInteger n=2;[NSFileManager.defaultManager fileExistsAtPath:candidate] && n<1000;n++)
        candidate=[directory stringByAppendingPathComponent:[[base stringByAppendingFormat:@" %lu",(unsigned long)n]
            stringByAppendingPathExtension:@"pdf"]];
    return candidate;
}
- (void)openTranslation:(NSString*)path besidePath:(NSString*)original {
    BOOL existed=[self indexOfTabForPath:path]>=0;
    [self openPath:path];
    NSInteger index=[self indexOfTabForPath:path], beside=original.length ? [self indexOfTabForPath:original] : -1;
    if (existed || index<0 || beside<0 || index==beside || ![self respondsToSelector:@selector(moveTabAtIndex:toGroup:atIndex:)])
        return;
    // Right after the original, in its group, where the person will look for it.
    SPDFTabGroup* group=_tabs[(NSUInteger)beside].group;
    if (index==beside+1 && _tabs[(NSUInteger)index].group==group) return;
    [(id<SPDFTabGroupReader>)self moveTabAtIndex:index toGroup:group atIndex:index>beside ? beside+1 : beside];
}
@end
