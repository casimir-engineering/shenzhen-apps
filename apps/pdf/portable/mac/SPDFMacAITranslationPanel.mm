#import "SPDFMacAITranslationPanel.h"
#import "SPDFMacCollectionStyle.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "SPDFMacAITranslation.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacAICredentials.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAILanguagePicker.h"
#import "SPDFMacAIOutputFiles.h"
#import <sys/stat.h>

BOOL SPDFMacAITranslationCanSaveToURL(NSURL* destination, NSString* sourcePath) {
    if(!destination.isFileURL || !sourcePath.length)return NO;
    if([destination.URLByResolvingSymlinksInPath.path isEqual:[NSURL fileURLWithPath:sourcePath].URLByResolvingSymlinksInPath.path])return NO;
    struct stat source={},output={};
    return stat(sourcePath.fileSystemRepresentation,&source)!=0 || stat(destination.path.fileSystemRepresentation,&output)!=0 ||
        source.st_dev!=output.st_dev || source.st_ino!=output.st_ino;
}

@implementation SPDFMacAITranslationPanel {
    NSTextView* _source; NSTextView* _result; NSTextField* _status;
    SPDFMacSearchablePicker* _language; NSButton* _send; NSButton* _cancel; NSButton* _save;
    SPDFMacAITranslation* _translation; NSString* _name; BOOL _busy; BOOL _closed;
}
- (instancetype)initWithSourceName:(NSString*)name language:(NSString*)language {
    NSPanel* panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,720,590)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if(!(self=[super initWithWindow:panel]))return nil;
    _name=name;_preparation=[NSProgress progressWithTotalUnitCount:-1];_protectedSourcePaths=@[name];_busy=YES; panel.title=[@"AI Translation — " stringByAppendingString:name.lastPathComponent];panel.releasedWhenClosed=NO;panel.minSize=NSMakeSize(600,470);panel.delegate=self;
    NSView* content=panel.contentView;
    NSTextField* info=[NSTextField wrappingLabelWithString:@"Send this text to OpenRouter using your selected model. The translation is saved as a new Markdown document in your Downloads folder. PDF page layout is not preserved; the original stays unchanged."];
    _language=SPDFMacAILanguagePicker(language,nil);_language.accessibilityLabel=@"Translate into";
    _status=[NSTextField wrappingLabelWithString:@"Preparing text…"];
    _source=[NSTextView new];_result=[NSTextView new];
    NSMutableArray* scrolls=[NSMutableArray array];
    for(NSTextView* text in @[_source,_result]) {
        text.richText=NO;text.font=[NSFont systemFontOfSize:13];text.textColor=SPDFCollectionColor(@"text");
        text.backgroundColor=SPDFCollectionColor(@"window");text.textContainerInset=NSMakeSize(8,8);
        text.autoresizingMask=NSViewWidthSizable;text.verticallyResizable=YES;text.horizontallyResizable=NO;
        text.textContainer.widthTracksTextView=YES;
        NSScrollView* scroll=[NSScrollView new];scroll.documentView=text;scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;
        [scrolls addObject:scroll];
    }
    _source.accessibilityLabel=@"Text to translate";_result.accessibilityLabel=@"Translated text";
    _send=[NSButton buttonWithTitle:@"Translate with AI" target:self action:@selector(send:)];_send.enabled=NO;
    _cancel=[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelOperation:)];_cancel.keyEquivalent=@"\e";_cancel.enabled=YES;
    _save=[NSButton buttonWithTitle:@"Save translated copy" target:self action:@selector(save:)];_save.enabled=NO;
    NSStackView* buttons=[NSStackView stackViewWithViews:@[_cancel,_send,_save]];buttons.spacing=8;
    NSTextField* sourceLabel=[NSTextField labelWithString:@"Source text"];
    NSTextField* resultLabel=[NSTextField labelWithString:@"Translation"];
    for(NSView* view in @[info,_language,sourceLabel,scrolls[0],resultLabel,scrolls[1],_status,buttons]) {
        view.translatesAutoresizingMaskIntoConstraints=NO;[content addSubview:view];
    }
    NSView* first=scrolls[0];NSView* second=scrolls[1];
    [NSLayoutConstraint activateConstraints:@[
        [info.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],[info.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],[info.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [_language.topAnchor constraintEqualToAnchor:info.bottomAnchor constant:12],[_language.leadingAnchor constraintEqualToAnchor:info.leadingAnchor],
        [sourceLabel.topAnchor constraintEqualToAnchor:_language.bottomAnchor constant:12],[sourceLabel.leadingAnchor constraintEqualToAnchor:info.leadingAnchor],
        [first.topAnchor constraintEqualToAnchor:sourceLabel.bottomAnchor constant:6],[first.leadingAnchor constraintEqualToAnchor:info.leadingAnchor],[first.trailingAnchor constraintEqualToAnchor:info.trailingAnchor],
        [resultLabel.topAnchor constraintEqualToAnchor:first.bottomAnchor constant:10],[resultLabel.leadingAnchor constraintEqualToAnchor:info.leadingAnchor],
        [second.topAnchor constraintEqualToAnchor:resultLabel.bottomAnchor constant:6],[second.leadingAnchor constraintEqualToAnchor:info.leadingAnchor],[second.trailingAnchor constraintEqualToAnchor:info.trailingAnchor],
        [second.heightAnchor constraintEqualToAnchor:first.heightAnchor],[first.heightAnchor constraintGreaterThanOrEqualToConstant:90],
        [_status.topAnchor constraintEqualToAnchor:second.bottomAnchor constant:10],[_status.leadingAnchor constraintEqualToAnchor:info.leadingAnchor],[_status.trailingAnchor constraintEqualToAnchor:info.trailingAnchor],
        [buttons.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:10],[buttons.trailingAnchor constraintEqualToAnchor:info.trailingAnchor],[buttons.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16]
    ]];return self;
}
- (void)setSourceText:(NSString*)text error:(NSError*)error {
    if(_preparation.cancelled)return;
    if(text.length>500000){text=nil;error=SPDFMacAIError(120,@"This document exceeds 500,000 characters. Select a smaller passage to translate.");}
    _source.string=text ?: @"";_result.string=@"";[self setBusy:NO];_send.enabled=text.length>0 && !error;
    _status.stringValue=error.localizedDescription ?: [NSString stringWithFormat:@"%lu characters · Review the text and choose a language before sending.",(unsigned long)text.length];
}
- (void)setBusy:(BOOL)busy {
    _busy=busy;_source.editable=!busy;_language.enabled=!busy;_send.enabled=!busy && _source.string.length;
    _cancel.enabled=YES;_cancel.title=busy ? @"Cancel" : @"Close";_save.enabled=!busy && _result.string.length;
}
- (void)send:(id)sender {
    (void)sender;if(_busy)return;
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    NSError* error=nil;[settings load:&error];
    if(error || !settings.enabled || !settings.connectionConfigured) {
        _status.stringValue=error.localizedDescription ?: @"Connect OpenRouter and enable AI in Settings, then retry.";return;
    }
    NSString* key=[SPDFMacAICredentials APIKeyWithError:&error];
    if(!key.length) {_status.stringValue=error.localizedDescription ?: @"Reconnect OpenRouter in Settings.";return;}
    _result.string=@"";[self setBusy:YES];
    if(!_translation)_translation=[[SPDFMacAITranslation alloc] initWithTransport:[[SPDFMacAITransport alloc] initWithConfiguration:nil]];
    __weak SPDFMacAITranslationPanel* weakSelf=self;
    [_translation translateText:_source.string language:_language.selectedID model:settings.model key:key
        progress:^(NSUInteger completed,NSUInteger total) {
            SPDFMacAITranslationPanel* owner=weakSelf;if(owner)owner->_status.stringValue=[NSString stringWithFormat:@"Translating part %lu of %lu…",(unsigned long)completed+1,(unsigned long)total];
        } completion:^(NSString* translated,NSError* failure) {
            SPDFMacAITranslationPanel* owner=weakSelf;if(!owner)return;
            owner->_result.string=translated ?: @"";[owner setBusy:NO];
            owner->_status.stringValue=failure.localizedDescription ?: @"Translation complete. Review before saving.";
        }];
}
- (void)cancelOperation:(id)sender {
    (void)sender;[_preparation cancel];[_translation cancel];if(_busy){[self setBusy:NO];_status.stringValue=@"Translation cancelled. No file was changed.";}else [self close];
}
- (void)windowWillClose:(NSNotification*)notification {
    (void)notification;if(_closed)return;_closed=YES;[_preparation cancel];[_translation cancel];
    _source.string=@"";_result.string=@"";[self setBusy:NO];
    void (^closed)(void)=self.onClosed;self.onClosed=nil;if(closed)closed();
}
- (void)save:(id)sender {
    (void)sender;if(_busy || !_result.string.length)return;
    // Straight to Downloads under a new name, never over a file there, the original included; then Collection.
    NSString* language=[[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLanguageCode:_language.selectedID ?: @""];
    NSString* name=SPDFMacAIOutputFileName([NSString stringWithFormat:@"%@ (%@)",
        _name.lastPathComponent.stringByDeletingPathExtension,language ?: _language.selectedID],@"Translation",@"md");
    NSData* data=[_result.string dataUsingEncoding:NSUTF8StringEncoding];void (^keep)(NSString*)=self.keepCopy;
    _save.enabled=NO;__weak SPDFMacAITranslationPanel* weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError* error=nil;NSDictionary* saved=SPDFMacAIOutputWriteData(data,SPDFMacAIDownloadsDirectory(),name,&error);
        if(saved && keep)keep(saved[@"path"]);
        dispatch_async(dispatch_get_main_queue(),^{
            SPDFMacAITranslationPanel* panel=weakSelf;if(!panel)return;
            panel->_save.enabled=!panel->_busy && panel->_result.string.length;
            if(!saved){panel->_status.stringValue=error.localizedDescription ?: @"The translation could not be saved.";return;}
            panel->_status.stringValue=[NSString stringWithFormat:@"Saved to Downloads as “%@”.",[saved[@"path"] lastPathComponent]];
            if(panel.openCopy)panel.openCopy(saved[@"path"]);
        });
    });
}
@end
