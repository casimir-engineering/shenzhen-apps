#import "SPDFMacTranslationChoice.h"
#import "SPDFMacDocumentToolInputIntegration.h"
#import "SPDFMacOCRChoicePopover.h"
#import "SPDFMacPictureText.h"
#import "SPDFMacPictureTextIntegration.h"
#import "SPDFMacSupport.h"
#import <objc/runtime.h>
#import "SPDFMacCollectionPathPolicy.h"

@interface ShenzhenMacDelegate (SPDFMacDocumentToolInputPrivate)
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (void)runOCRWithLanguage:(NSString*)language displayName:(NSString*)displayName;
@end

@implementation ShenzhenMacDelegate (SPDFMacDocumentToolInput)

// Asks who reads the text, open source or macOS, as Translate asks who translates (SPDFMacOCRChoicePopover.h).
- (void)ocrDocument:(id)sender {
    if (!_doc || !SPDFOCRPathSupported(_path)) { NSBeep(); return; }
    // Under the button when it is in the toolbar; from the File or overflow menu, under the toolbar's right end.
    NSView* anchor = _ocrButton.window && !_ocrButton.hidden && _ocrButton.superview ? _ocrButton :
        ([sender isKindOfClass:NSView.class] ? sender : _toolbar);
    __weak ShenzhenMacDelegate* weakSelf = self;
    [SPDFMacOCRChoicePopover showRelativeToView:anchor languages:spdf_ocr_languages()
                                            run:^(NSString* engine, NSDictionary<NSString*, NSString*>* language) {
        if ([engine isEqualToString:SPDFMacOCREngineMacOS]) [weakSelf recognizeShownDocumentTextOnThisMac];
        else [weakSelf runOCRWithLanguage:language[@"code"] displayName:language[@"name"]];
    }];
}

- (void)prepareDocumentToolPDFWithSuffix:(NSString*)suffix completion:(void (^)(void))completion {
    static char preparingKey;
    if ([objc_getAssociatedObject(self, &preparingKey) boolValue]) return;
    NSString* source = [_path copy];
    NSString* destination = nil;
    if (SPDFMacPathIsCollectionArchive(source) ||
        ![NSFileManager.defaultManager isWritableFileAtPath:source.stringByDeletingLastPathComponent]) {
        // Collection snapshots are read-only; derived files belong in a folder
        // chosen by the reader, never inside the managed archive/cache.
        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.title = @"Choose a folder for the PDF copy";
        panel.prompt = @"Create PDF Here"; panel.canChooseFiles = NO; panel.canChooseDirectories = YES;
        panel.canCreateDirectories = YES;
        if ([panel runModal] != NSModalResponseOK) return;
        destination = panel.URL.path;
    }
    objc_setAssociatedObject(self, &preparingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _statusLabel.stringValue = @"Preparing a PDF copy…";
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError* error = nil;
            NSString* output = SPDFCreateToolPDF(source, suffix, &error, destination);
            dispatch_async(dispatch_get_main_queue(), ^{
                ShenzhenMacDelegate* owner = weakSelf;
                if (!owner) return;
                objc_setAssociatedObject(owner, &preparingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!output) { [owner showError:@"Could not prepare PDF copy" detail:error.localizedDescription]; return; }
                [owner openPath:output];
                if ([owner->_path isEqualToString:output] && owner->_doc) completion();
            });
        }
    });
}

- (BOOL)beginImageOCRWithLanguage:(NSString*)language displayName:(NSString*)displayName {
    if (!_doc || !SPDFOCRPathNeedsPDF(_path)) return NO;
    __weak ShenzhenMacDelegate* weakSelf = self;
    [self prepareDocumentToolPDFWithSuffix:@"ocr" completion:^{
        [weakSelf runOCRWithLanguage:language displayName:displayName];
    }];
    return YES;
}

- (BOOL)beginNativeDocumentTranslation {
    if (!_doc || [_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) return NO;
    __weak ShenzhenMacDelegate* weakSelf = self;
    [self noteLocalTranslationMakesPDF];
    [self prepareDocumentToolPDFWithSuffix:@"translation-source" completion:^{ [weakSelf translateDocumentLocally:nil]; }];
    return YES;
}
@end
