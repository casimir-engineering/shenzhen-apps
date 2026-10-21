#import "SPDFMacAIToolArguments.h"
#include <vector>
const NSUInteger SPDFMacAIToolArgumentsLimit=65536;
static NSDictionary* StrictObject(NSString* text) {
    NSData* data=[text dataUsingEncoding:NSUTF8StringEncoding];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static BOOL IsHex(unichar c) { return (c>='0' && c<='9') || (c>='a' && c<='f') || (c>='A' && c<='F'); }
// UTF-16 units copied one by one, so a surrogate pair is carried over as the two units it came in.
typedef std::vector<unichar> Units;
static void AppendASCII(Units& out,const char* text) { while (*text) out.push_back((unichar)*text++); }
static void AppendControl(Units& out,unichar c) {
    switch (c) {
        case '\n': AppendASCII(out,"\\n"); break;
        case '\r': AppendASCII(out,"\\r"); break;
        case '\t': AppendASCII(out,"\\t"); break;
        case '\b': AppendASCII(out,"\\b"); break;
        case '\f': AppendASCII(out,"\\f"); break;
        default: { char escape[8]; snprintf(escape,sizeof escape,"\\u%04x",(unsigned)c); AppendASCII(out,escape); }
    }
}
// Drops surrounding whitespace and one Markdown code fence ("```json" … "```") around the object.
static NSString* Unfenced(NSString* text) {
    NSCharacterSet* space=NSCharacterSet.whitespaceAndNewlineCharacterSet;
    text=[text stringByTrimmingCharactersInSet:space];
    if (![text hasPrefix:@"```"]) return text;
    NSRange line=[text rangeOfString:@"\n"];
    if (line.location==NSNotFound) return text;
    text=[text substringFromIndex:NSMaxRange(line)];
    if ([text hasSuffix:@"```"]) text=[text substringToIndex:text.length-3];
    return [text stringByTrimmingCharactersInSet:space];
}
// One pass over the first object: strings are repaired as the header describes, everything outside them is copied
// unchanged, so strict JSON decides the rest. `end` is the index just past the object's last brace.
static SPDFMacAIToolArgumentsProblem Repair(NSString* text,Units& out,NSUInteger* end) {
    NSUInteger n=text.length;
    if (!n || [text characterAtIndex:0]!='{') return SPDFMacAIToolArgumentsInvalid;
    Units closers; BOOL inString=NO;
    for (NSUInteger i=0;i<n;i++) {
        unichar c=[text characterAtIndex:i];
        if (inString) {
            if (c=='"') { inString=NO; out.push_back(c); }
            else if (c<0x20) AppendControl(out,c);
            else if (c!='\\') out.push_back(c);
            else {
                if (i+1>=n) return SPDFMacAIToolArgumentsTruncated;
                unichar d=[text characterAtIndex:++i];
                if (d=='u') {
                    if (i+4>=n) return SPDFMacAIToolArgumentsTruncated;
                    for (NSUInteger k=1;k<=4;k++)
                        if (!IsHex([text characterAtIndex:i+k])) return SPDFMacAIToolArgumentsInvalid;
                    for (NSUInteger k=0;k<6;k++) out.push_back([text characterAtIndex:i-1+k]);
                    i+=4;
                } else if (d=='"' || d=='\\' || d=='/' || d=='b' || d=='f' || d=='n' || d=='r' || d=='t')
                    { out.push_back('\\'); out.push_back(d); }
                else if (d<0x20) AppendControl(out,d); // a backslash before a raw line break: the break itself
                else out.push_back(d);                // \' and the like: the character itself
            }
            continue;
        }
        out.push_back(c);
        if (c=='"') inString=YES;
        else if (c=='{') closers.push_back('}');
        else if (c=='[') closers.push_back(']');
        else if (c=='}' || c==']') {
            if (closers.empty() || closers.back()!=c) return SPDFMacAIToolArgumentsInvalid;
            closers.pop_back();
            if (closers.empty()) { *end=i+1; return SPDFMacAIToolArgumentsReadable; }
        }
    }
    return SPDFMacAIToolArgumentsTruncated;
}
NSDictionary* SPDFMacAIToolCallArguments(id raw,SPDFMacAIToolArgumentsProblem* problem,BOOL* repaired) {
    SPDFMacAIToolArgumentsProblem ignored; if (!problem) problem=&ignored;
    BOOL unused; if (!repaired) repaired=&unused;
    *problem=SPDFMacAIToolArgumentsInvalid; *repaired=NO;
    if ([raw isKindOfClass:NSDictionary.class]) {
        if (![NSJSONSerialization isValidJSONObject:raw]) return nil;
        *problem=SPDFMacAIToolArgumentsReadable; *repaired=YES; return raw;
    }
    if (![raw isKindOfClass:NSString.class]) return nil;
    NSString* text=raw;
    if (text.length>SPDFMacAIToolArgumentsLimit) { *problem=SPDFMacAIToolArgumentsTooLong; return nil; }
    NSDictionary* strict=StrictObject(text);
    if (strict) { *problem=SPDFMacAIToolArgumentsReadable; return strict; }
    text=Unfenced(text);
    Units out; out.reserve(text.length+64); NSUInteger end=0;
    SPDFMacAIToolArgumentsProblem found=Repair(text,out,&end);
    if (found!=SPDFMacAIToolArgumentsReadable) { *problem=found; return nil; }
    // Another value after the object may be a second call run into this one: neither is run.
    NSString* rest=[[text substringFromIndex:end] stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n,"]];
    if ([rest hasPrefix:@"{"] || [rest hasPrefix:@"["]) return nil;
    NSDictionary* object=StrictObject([NSString stringWithCharacters:out.data() length:out.size()]);
    if (!object) return nil;
    *problem=SPDFMacAIToolArgumentsReadable; *repaired=YES; return object;
}
NSString* SPDFMacAIToolArgumentsJSON(NSDictionary* arguments) {
    NSData* data=[NSJSONSerialization isValidJSONObject:arguments] ?
        [NSJSONSerialization dataWithJSONObject:arguments options:NSJSONWritingWithoutEscapingSlashes error:nil] : nil;
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
