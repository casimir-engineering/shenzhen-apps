#pragma once
#import <Foundation/Foundation.h>
// Menus need only a short preview. Never normalize an entire multi-page selection
// on the main thread just to display forty characters.
static inline NSString* SPDFMenuSelectionPreview(NSString* selected) {
    if (!selected.length) return @"";
    NSUInteger length=MIN(selected.length,(NSUInteger)256);
    NSRange sample=[selected rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,length)];
    NSString* text=[[selected substringWithRange:sample] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    text=[text stringByReplacingOccurrencesOfString:@"[\\s\\u00a0]+" withString:@" " options:NSRegularExpressionSearch range:NSMakeRange(0,text.length)];
    if (text.length <= 42 && sample.length == selected.length) return text;
    if (!text.length) return @"";
    NSRange prefix=[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,MIN((NSUInteger)39,text.length))];
    return [[text substringWithRange:prefix] stringByAppendingString:@"…"];
}
