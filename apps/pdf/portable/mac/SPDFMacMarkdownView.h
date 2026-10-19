#pragma once

#import <AppKit/AppKit.h>

@class SPDFMarkdownDocumentModel;
@class SPDFMarkdownRenderedDocument;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSAttributedStringKey const SPDFMacMarkdownDestinationAttribute;
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMacMarkdownWikiDestinationAttribute;

NSAttributedString* SPDFMacMarkdownInteractiveString(SPDFMarkdownDocumentModel* model,
                                                     SPDFMarkdownRenderedDocument* rendered);

@protocol SPDFMacMarkdownTextViewEventDelegate <NSObject>
- (void)markdownTextView:(NSTextView*)textView
       activateDestination:(NSString*)destination
                  wikiLink:(BOOL)wikiLink;
- (void)markdownTextView:(NSTextView*)textView chooseLanguageForCodeBlock:(NSUInteger)blockIndex;
@end

@interface SPDFMacMarkdownTextView : NSTextView
@property(nonatomic, weak, nullable) id<SPDFMacMarkdownTextViewEventDelegate> markdownEventDelegate;
@end

NS_ASSUME_NONNULL_END
