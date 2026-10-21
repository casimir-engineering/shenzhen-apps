#import "SPDFMacTranslationChoice.h"
#import "SPDFMacTranslationEnablement.h"
#import "SPDFMacAITranslationPanel.h"
#import "SPDFMacAIOutputs.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacAITranslation.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "markdown/SPDFTextDocumentParser.h"
#import <objc/runtime.h>

@interface ShenzhenMacDelegate (SPDFMacTranslationChoicePrivate)
- (NSString*)trimmedSelectedTextForCommand;
- (NSString*)activeWorkingPath;
- (spdf_document*)workerDocumentForPath:(NSString*)path sourcePath:(NSString*)source error:(char*)error errorLength:(size_t)length;
@end
@implementation ShenzhenMacDelegate (SPDFMacTranslationChoice)
- (void)translateDocument:(id)sender {
    if(!spdf_translation_command_enabled([self translationContext]))return;
    NSMenu* menu=SPDFMacTranslationChoiceMenu(self);
    NSView* anchor=[sender isKindOfClass:NSView.class] ? sender : _translateButton;
    if(anchor.window && !anchor.hidden) {
        NSPoint point=NSMakePoint(NSMinX(anchor.bounds),anchor.isFlipped ? NSMaxY(anchor.bounds)+3 : NSMinY(anchor.bounds)-3);
        [menu popUpMenuPositioningItem:nil atLocation:point inView:anchor];
    } else [menu popUpMenuPositioningItem:nil atLocation:NSEvent.mouseLocation inView:nil];
}
- (void)translateDocumentWithAI:(id)sender {
    (void)sender;if(!spdf_translation_command_enabled([self translationContext]))return;
    static char panelKey;
    NSMutableArray* panels=objc_getAssociatedObject(self,&panelKey);
    if(!panels){panels=[NSMutableArray array];objc_setAssociatedObject(self,&panelKey,panels,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    for(SPDFMacAITranslationPanel* previous in panels.copy)if(!previous.window.visible)[panels removeObject:previous];
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];[settings load:nil];
    SPDFMacAITranslationPanel* panel=[[SPDFMacAITranslationPanel alloc] initWithSourceName:_path language:settings.language];
    panel.protectedSourcePaths=@[_path ?: @"",[self activeWorkingPath] ?: @""];[panels addObject:panel];
    __weak NSMutableArray* weakPanels=panels;__weak SPDFMacAITranslationPanel* weakPanel=panel;
    panel.onClosed=^{SPDFMacAITranslationPanel* closed=weakPanel;if(closed)[weakPanels removeObject:closed];};
    __weak ShenzhenMacDelegate* weakSelf=self;panel.openCopy=^(NSString* path){[weakSelf openPath:path];};
    panel.keepCopy=^(NSString* path){SPDFMacAIOutputKeepInCollection(path,SPDFMacCollectionStore.defaultStore);};
    [panel.window center];[panel showWindow:nil];
    NSString* selected=[self trimmedSelectedTextForCommand];
    if(selected.length){[panel setSourceText:selected error:nil];return;}
    BOOL textDocument=[self isMarkdownActive];
    NSString* path=[[self activeWorkingPath] copy];NSString* source=[_path copy];
    // Independent worker document: no rendering, extraction or network work on launch or the reader thread.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            char errorText[1024]={};NSError* failure=nil;NSMutableString* text=[NSMutableString string];
            if(textDocument) {
                NSNumber* bytes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:&failure][NSFileSize];
                NSString* raw=nil;
                if(bytes.unsignedLongLongValue>2000004)failure=SPDFMacAIError(120,@"This document is too large. Select a smaller passage to translate.");
                if(!failure && !panel.preparation.cancelled) {
                    NSData* data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&failure];
                    if(data)raw=SPDFDecodeSourceDocument(data,&failure);
                }
                dispatch_async(dispatch_get_main_queue(),^{[panel setSourceText:raw error:failure];});return;
            }
            spdf_document* doc=panel.preparation.cancelled ? NULL : [self workerDocumentForPath:path sourcePath:source error:errorText errorLength:sizeof(errorText)];
            if(!doc)failure=SPDFMacAIError(122,errorText[0] ? @(errorText) : @"Could not read document text.");
            for(int page=0;doc && !panel.preparation.cancelled && page<spdf_page_count(doc);++page) {
                spdf_text_lines lines={};
                if(!spdf_extract_page_text_lines(doc,page,&lines,errorText,sizeof(errorText))) {
                    failure=SPDFMacAIError(122,@"Could not extract all pages. No text was sent.");break;
                }
                for(int line=0;line<lines.count;++line) {
                    NSString* value=lines.items[line].text ? @(lines.items[line].text) : @"";
                    if(!SPDFMacAITranslationAppendLine(text,value,panel.preparation,&failure))break;
                }
                spdf_free_text_lines(&lines);
                if(failure || !SPDFMacAITranslationAppendLine(text,@"",panel.preparation,&failure))break;
            }
            // workerDocumentForPath is owned by the thread-local cache; never close it here.
            if(!failure && ![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
                failure=SPDFMacAIError(123,@"No selectable text. Run OCR first for scanned pages.");
            dispatch_async(dispatch_get_main_queue(),^{[panel setSourceText:failure ? nil : text error:failure];});
        }
    });
}
@end
