#import "SPDFMacAITranslation.h"
#import "SPDFMacAITransport.h"

NSArray<NSString*>* SPDFMacAITranslationChunks(NSString* text, NSError** error) {
    if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length || text.length>500000) {
        if(error)*error=SPDFMacAIError(120,text.length>500000 ? @"This document is longer than 500,000 characters, too long to translate at once." : @"There is no text to translate.");
        return nil;
    }
    NSMutableArray* chunks=[NSMutableArray array]; NSUInteger offset=0;
    while(offset<text.length) {
        NSUInteger length=MIN((NSUInteger)3000,text.length-offset);
        if(offset+length<text.length) {
            NSRange paragraph=[text rangeOfString:@"\n" options:NSBackwardsSearch range:NSMakeRange(offset,length)];
            if(paragraph.location!=NSNotFound && paragraph.location>offset+1500) length=NSMaxRange(paragraph)-offset;
        }
        NSRange range=[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(offset,length)];
        [chunks addObject:[text substringWithRange:range]]; offset=NSMaxRange(range);
    }
    return chunks;
}
