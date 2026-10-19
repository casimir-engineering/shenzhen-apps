#pragma once
#import <Foundation/Foundation.h>
// Stable identifiers are persisted, never translated labels or free-form prompt text.
static inline NSDictionary<NSString*,NSString*>* SPDFMacAILanguageNames(void) {
    static NSDictionary* names; static dispatch_once_t once;
    dispatch_once(&once,^{ names=@{
        @"en":@"English",@"fr":@"French",@"de":@"German",@"es":@"Spanish",@"it":@"Italian",
        @"pt":@"Portuguese",@"pt-BR":@"Portuguese (Brazil)",@"zh-Hans":@"Chinese (Simplified)",
        @"zh-Hant":@"Chinese (Traditional)",@"ja":@"Japanese",@"ko":@"Korean",@"ar":@"Arabic",
        @"hi":@"Hindi",@"bn":@"Bengali",@"ur":@"Urdu",@"ru":@"Russian",@"uk":@"Ukrainian",
        @"pl":@"Polish",@"nl":@"Dutch",@"sv":@"Swedish",@"da":@"Danish",@"no":@"Norwegian",
        @"fi":@"Finnish",@"is":@"Icelandic",@"el":@"Greek",@"tr":@"Turkish",@"he":@"Hebrew",
        @"fa":@"Persian",@"id":@"Indonesian",@"ms":@"Malay",@"vi":@"Vietnamese",@"th":@"Thai",
        @"cs":@"Czech",@"sk":@"Slovak",@"hu":@"Hungarian",@"ro":@"Romanian",@"bg":@"Bulgarian",
        @"hr":@"Croatian",@"sr":@"Serbian",@"sl":@"Slovenian",@"et":@"Estonian",@"lv":@"Latvian",
        @"lt":@"Lithuanian",@"ca":@"Catalan",@"eu":@"Basque",@"gl":@"Galician",@"ga":@"Irish",
        @"sw":@"Swahili",@"af":@"Afrikaans",@"ta":@"Tamil",@"te":@"Telugu",@"mr":@"Marathi",
        @"gu":@"Gujarati",@"kn":@"Kannada",@"ml":@"Malayalam",@"pa":@"Punjabi",@"ne":@"Nepali",
        @"fil":@"Filipino",@"km":@"Khmer",@"lo":@"Lao",@"my":@"Burmese",@"mn":@"Mongolian",
        @"ka":@"Georgian",@"hy":@"Armenian",@"az":@"Azerbaijani",@"kk":@"Kazakh",@"uz":@"Uzbek"
    }; }); return names;
}
static inline NSString* SPDFMacAILanguageName(NSString* code) {
    return code ? (SPDFMacAILanguageNames()[code] ?: @"English") : @"English";
}
static inline NSArray<NSDictionary*>* SPDFMacAILanguageChoices(void) {
    NSMutableArray* choices=[NSMutableArray array];
    for(NSString* code in SPDFMacAILanguageNames()) {
        NSString* native=[[[NSLocale alloc] initWithLocaleIdentifier:code] localizedStringForLocaleIdentifier:code];
        // NSLocale names remain UI-only; provider prompts use our fixed English labels.
        NSString* english=SPDFMacAILanguageName(code);
        NSString* name=native.length && ![native isEqual:english] ? [NSString stringWithFormat:@"%@ · %@",english,native] : english;
        [choices addObject:@{@"id":code,@"name":name}];
    }
    return [choices sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b){return [a[@"name"] compare:b[@"name"]];}];
}
