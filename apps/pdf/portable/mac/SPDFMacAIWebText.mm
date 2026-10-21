#import "SPDFMacAIWebText.h"
#import "SPDFMacAIWebAddress.h"
#import "SPDFMacAIWebEntities.h"
#include <string>
#include <vector>

static const NSUInteger kMaximumLinks = 100;
static const NSUInteger kMaximumLinkText = 120;

@implementation SPDFMacAIWebReadable
- (instancetype)initWithTitle:(NSString*)title text:(NSString*)text truncated:(BOOL)truncated
                        links:(NSArray<NSDictionary<NSString*, NSString*>*>*)links {
    if (!(self = [super init])) return nil;
    _title = [title copy] ?: @"";
    _text = [text copy] ?: @"";
    _truncated = truncated;
    _links = [links copy] ?: @[];
    return self;
}
@end

#pragma mark - Decoding

static NSString* LossyUTF8(const uint8_t* bytes, size_t length) {
    std::vector<unichar> out;
    out.reserve(length);
    for (size_t index = 0; index < length;) {
        uint8_t lead = bytes[index];
        if (lead < 0x80) { out.push_back(lead); index++; continue; }
        size_t need = (lead & 0xE0) == 0xC0 ? 1 : (lead & 0xF0) == 0xE0 ? 2 : (lead & 0xF8) == 0xF0 ? 3 : 0;
        uint32_t point = need == 1 ? lead & 0x1F : need == 2 ? lead & 0x0F : lead & 0x07;
        size_t continued = 0;
        while (continued < need && index + 1 + continued < length && (bytes[index + 1 + continued] & 0xC0) == 0x80) {
            point = (point << 6) | (bytes[index + 1 + continued] & 0x3F);
            continued++;
        }
        uint32_t minimum = need == 1 ? 0x80 : need == 2 ? 0x800 : 0x10000;
        if (!need || continued < need || point < minimum || point > 0x10FFFF || (point >= 0xD800 && point <= 0xDFFF)) {
            // One replacement for the whole broken sequence, as browsers show it (a body cut mid-character included).
            out.push_back(0xFFFD);
            index += 1 + continued;
            continue;
        }
        if (point >= 0x10000) {
            point -= 0x10000;
            out.push_back((unichar)(0xD800 + (point >> 10)));
            out.push_back((unichar)(0xDC00 + (point & 0x3FF)));
        } else out.push_back((unichar)point);
        index += need + 1;
    }
    return [NSString stringWithCharacters:out.data() length:out.size()];
}

static NSString* CharsetIn(NSString* text) {
    NSRange found = [text rangeOfString:@"charset=" options:NSCaseInsensitiveSearch];
    if (found.location == NSNotFound) return nil;
    NSString* rest = [text substringFromIndex:NSMaxRange(found)];
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \"'"]];
    NSCharacterSet* name = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:."];
    NSRange end = [rest rangeOfCharacterFromSet:name.invertedSet];
    NSString* charset = end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
    return charset.length ? charset : nil;
}

NSString* SPDFMacAIWebDecodeText(NSData* body, NSString* contentType, BOOL html) {
    const uint8_t* bytes = (const uint8_t*)body.bytes;
    NSUInteger length = body.length;
    if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
        return LossyUTF8(bytes + 3, length - 3);
    if (length >= 2 && ((bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE))) {
        NSString* text = [[NSString alloc] initWithData:body encoding:NSUTF16StringEncoding];
        if (text) return text;
    }
    NSString* charset = CharsetIn(contentType ?: @"");
    if (!charset && html) {
        // A <meta charset> must sit in the first 1024 bytes (HTML § 13.2.3.2); Latin-1 reads any byte.
        NSData* head = [body subdataWithRange:NSMakeRange(0, MIN(length, (NSUInteger)1024))];
        NSString* prefix = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding];
        NSRange meta = [prefix rangeOfString:@"<meta" options:NSCaseInsensitiveSearch];
        if (meta.location != NSNotFound) charset = CharsetIn([prefix substringFromIndex:meta.location]);
    }
    CFStringEncoding encoding = charset ? CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)charset) :
        kCFStringEncodingInvalidId;
    if (encoding != kCFStringEncodingInvalidId && encoding != kCFStringEncodingUTF8) {
        NSString* text = [[NSString alloc] initWithData:body
                                               encoding:CFStringConvertEncodingToNSStringEncoding(encoding)];
        if (text) return text;
    }
    return LossyUTF8(bytes, length);
}

#pragma mark - Entities

// The character an entity at s[i] ('&') names, and where it ends; 0 when it is not one (the '&' is then text).
static uint32_t Entity(const std::vector<unichar>& s, size_t i, size_t* end) {
    size_t j = i + 1, limit = MIN(s.size(), i + 34);
    while (j < limit && s[j] != ';' && (isalnum(s[j] < 128 ? s[j] : 0) || s[j] == '#')) j++;
    if (j >= limit || s[j] != ';' || j == i + 1) return 0;
    *end = j + 1;
    if (s[i + 1] == '#') {
        BOOL hex = j > i + 2 && (s[i + 2] == 'x' || s[i + 2] == 'X');
        std::string digits;
        for (size_t k = i + (hex ? 3 : 2); k < j; k++) digits.push_back((char)s[k]);
        if (digits.empty() || digits.size() > 8) return 0xFFFD;
        char* stop = NULL;
        unsigned long value = strtoul(digits.c_str(), &stop, hex ? 16 : 10);
        if (*stop) return 0;
        return !value || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) ? 0xFFFD : (uint32_t)value;
    }
    NSString* name = [NSString stringWithCharacters:s.data() + i + 1 length:j - i - 1];
    return SPDFMacAIWebNamedEntity(name);
}

#pragma mark - HTML

static inline BOOL Space(unichar c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'; }
static inline unichar Lower(unichar c) { return c >= 'A' && c <= 'Z' ? (unichar)(c + 32) : c; }
static inline BOOL Letter(unichar c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

static NSString* Decoded(const std::vector<unichar>& s, size_t from, size_t to) {
    std::vector<unichar> out;
    for (size_t k = from; k < to;) {
        size_t end = 0;
        uint32_t value = s[k] == '&' ? Entity(s, k, &end) : 0;
        if (!value || end > to) { out.push_back(s[k++]); continue; }
        if (value >= 0x10000) {
            value -= 0x10000;
            out.push_back((unichar)(0xD800 + (value >> 10)));
            out.push_back((unichar)(0xDC00 + (value & 0x3FF)));
        } else out.push_back((unichar)value);
        k = end;
    }
    return [NSString stringWithCharacters:out.data() length:out.size()];
}

static NSString* Collapsed(NSString* text, NSUInteger maximum) {
    NSArray* words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* joined = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
    if (joined.length <= maximum) return joined;
    return [joined substringWithRange:[joined rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, maximum)]];
}

namespace {
struct Extractor {
    std::vector<unichar> s;
    size_t i = 0;
    std::vector<unichar> out;
    NSUInteger bytes = 0, limit = 0;
    BOOL truncated = NO;
    int pendingBreak = 0;
    BOOL pendingSpace = NO, pendingCell = NO;
    int pre = 0;
    NSURL* base = nil;
    BOOL baseSet = NO;
    NSString* title = @"";
    NSMutableArray* links = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    NSString* anchor = nil; // the open <a>'s https target
    size_t anchorStart = 0;

    BOOL markup = YES;
    BOOL scripts = NO;

    BOOL Put(uint32_t c) {
        if (c >= 0x10000) {
            if (bytes + 4 > limit) { truncated = YES; return NO; }
            c -= 0x10000;
            out.push_back((unichar)(0xD800 + (c >> 10)));
            out.push_back((unichar)(0xDC00 + (c & 0x3FF)));
            bytes += 4;
            return YES;
        }
        NSUInteger size = c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
        if (bytes + size > limit) { truncated = YES; return NO; }
        out.push_back((unichar)c);
        bytes += size;
        return YES;
    }
    void Flush() {
        if (!out.empty()) {
            if (pendingBreak) for (int k = 0; k < pendingBreak; k++) Put('\n');
            else if (pendingCell) { Put(' '); Put('|'); Put(' '); }
            else if (pendingSpace) Put(' ');
        }
        pendingBreak = 0;
        pendingSpace = pendingCell = NO;
    }
    void Text(uint32_t c) {
        // Formatting characters and controls carry nothing a reader sees.
        if (c == 0xAD || (c >= 0x200B && c <= 0x200F) || c == 0x2060 || c == 0xFEFF || (c >= 0x7F && c < 0xA0)) return;
        BOOL space = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == 0xA0;
        if (c < 0x20 && !space) return;
        if (pre && space && c != 0xA0) {
            Flush();
            Put(c == '\r' || c == '\f' ? '\n' : c);
            return;
        }
        if (space) { pendingSpace = YES; return; }
        Flush();
        Put(c);
    }
    void Block(int lines) {
        if (!out.empty()) pendingBreak = MAX(pendingBreak, lines);
        pendingSpace = pendingCell = NO;
    }
    void Prefix(NSString* text) {
        Flush();
        for (NSUInteger k = 0; k < text.length; k++) Put([text characterAtIndex:k]);
    }
    size_t Find(const char* needle, size_t from) {
        size_t length = strlen(needle);
        for (size_t k = from; k + length <= s.size(); k++) {
            size_t m = 0;
            while (m < length && Lower(s[k + m]) == (unichar)needle[m]) m++;
            if (m == length) return k;
        }
        return s.size();
    }
    // Whether the tag name `name` starts at `at` and ends there (a space, '/', '>' or the end follows).
    BOOL NameAt(size_t at, NSString* name) {
        for (NSUInteger m = 0; m < name.length; m++)
            if (at + m >= s.size() || Lower(s[at + m]) != [name characterAtIndex:m]) return NO;
        size_t after = at + name.length;
        return after >= s.size() || s[after] == '>' || s[after] == '/' || Space(s[after]);
    }
    void SkipPast(unichar mark) {
        while (i < s.size() && s[i] != mark) i++;
        if (i < s.size()) i++;
    }
    // Skips a raw-text element (script, style, ...) to past its end tag, returning the text it held.
    NSString* SkipRaw(NSString* name) {
        size_t start = i;
        std::string needle = std::string("</") + name.UTF8String;
        size_t at = Find(needle.c_str(), i);
        while (at < s.size() && !NameAt(at + 2, name)) at = Find(needle.c_str(), at + 1);
        NSString* raw = [NSString stringWithCharacters:s.data() + start length:at - start];
        i = at;
        SkipPast('>');
        return raw;
    }
    void Run();
    void Tag();
    NSString* Attributes(NSString* wanted, BOOL* selfClosing);
    void SkipNested(NSString* name);
    void CloseAnchor();
};
}

void Extractor::Run() {
    while (i < s.size() && !truncated) {
        unichar c = s[i];
        if (markup && c == '<') { Tag(); continue; }
        size_t end = 0;
        uint32_t value = markup && c == '&' ? Entity(s, i, &end) : 0;
        if (value) { Text(value); i = end; continue; }
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.size() && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
            Text(0x10000 + ((uint32_t)(c - 0xD800) << 10) + (s[i + 1] - 0xDC00));
            i += 2;
            continue;
        }
        Text(c >= 0xD800 && c <= 0xDFFF ? 0xFFFD : c);
        i++;
    }
    CloseAnchor();
}

// From after a tag name to past its '>': the value of `wanted`, entities decoded, quotes respected (a '>' inside a
// quoted value does not end the tag).
NSString* Extractor::Attributes(NSString* wanted, BOOL* selfClosing) {
    NSString* found = nil;
    while (i < s.size()) {
        while (i < s.size() && Space(s[i])) i++;
        if (i >= s.size()) break;
        if (s[i] == '>') { i++; break; }
        if (s[i] == '/') { *selfClosing = i + 1 < s.size() && s[i + 1] == '>'; i++; continue; }
        size_t nameStart = i;
        while (i < s.size() && !Space(s[i]) && s[i] != '=' && s[i] != '>' && s[i] != '/') i++;
        if (i == nameStart) { i++; continue; } // a stray '='
        NSString* name = [[NSString stringWithCharacters:s.data() + nameStart length:i - nameStart] lowercaseString];
        while (i < s.size() && Space(s[i])) i++;
        if (i >= s.size() || s[i] != '=') continue;
        i++;
        while (i < s.size() && Space(s[i])) i++;
        size_t valueStart = i, valueEnd;
        if (i < s.size() && (s[i] == '"' || s[i] == '\'')) {
            unichar quote = s[i++];
            valueStart = i;
            while (i < s.size() && s[i] != quote) i++;
            valueEnd = i;
            if (i < s.size()) i++;
        } else {
            while (i < s.size() && !Space(s[i]) && s[i] != '>') i++;
            valueEnd = i;
        }
        if (wanted && !found && [name isEqual:wanted] && valueEnd - valueStart <= 4096)
            found = Decoded(s, valueStart, valueEnd);
    }
    return found;
}

// Skips an element whose content is not text (svg, math, template, media fallbacks), counting nested ones.
void Extractor::SkipNested(NSString* name) {
    NSUInteger depth = 1;
    while (i < s.size() && depth) {
        while (i < s.size() && s[i] != '<') i++;
        if (i >= s.size()) return;
        i++;
        BOOL close = i < s.size() && s[i] == '/';
        size_t at = close ? i + 1 : i;
        if (!NameAt(at, name)) continue;
        i = at;
        SkipPast('>');
        BOOL selfClose = i >= 2 && s[i - 1] == '>' && s[i - 2] == '/';
        if (close) depth--;
        else if (!selfClose) depth++;
    }
}

void Extractor::CloseAnchor() {
    if (!anchor) return;
    NSString* text = anchorStart < out.size() ?
        [NSString stringWithCharacters:out.data() + anchorStart length:out.size() - anchorStart] : @"";
    if (links.count < kMaximumLinks && ![seen containsObject:anchor]) {
        [seen addObject:anchor];
        [links addObject:@{@"text" : Collapsed(text, kMaximumLinkText), @"url" : anchor}];
    }
    anchor = nil;
}

static NSSet* Words(NSString* list) { return [NSSet setWithArray:[list componentsSeparatedByString:@" "]]; }

void Extractor::Tag() {
    static NSSet *raw, *nested, *paragraphs, *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        raw = Words(@"script style noscript iframe noembed noframes textarea xmp");
        nested = Words(@"svg math template canvas object video audio select");
        paragraphs = Words(@"p blockquote table ul ol dl section article header footer main aside nav figure form "
                           "details address center fieldset hr");
        lines = Words(@"div tr li dt dd caption figcaption summary legend option body html dialog menu dir tbody "
                      "thead tfoot");
    });
    size_t open = i;
    unichar next = i + 1 < s.size() ? s[i + 1] : 0;
    if (next == '!' && i + 3 < s.size() && s[i + 2] == '-' && s[i + 3] == '-') {
        size_t close = Find("-->", i + 4);
        i = close < s.size() ? close + 3 : s.size();
        return;
    }
    if (next == '!' || next == '?') { SkipPast('>'); return; } // doctype, CDATA, processing instruction
    BOOL end = next == '/';
    size_t start = i + (end ? 2 : 1);
    if (start >= s.size() || !Letter(s[start])) {
        if (end) SkipPast('>'); // "</ 3>" is a bogus comment in HTML, not text
        else { Text('<'); i = open + 1; }
        return;
    }
    std::string bytes;
    for (i = start; i < s.size() && (Letter(s[i]) || (s[i] >= '0' && s[i] <= '9') || s[i] == '-' || s[i] == ':');
         i++)
        if (bytes.size() < 32) bytes.push_back((char)Lower(s[i]));
    NSString* name = @(bytes.c_str());
    BOOL selfClosing = NO, link = !end && ([name isEqual:@"a"] || [name isEqual:@"base"]);
    NSString* href = Attributes(link ? @"href" : nil, &selfClosing);
    BOOL heading = name.length == 2 && [name characterAtIndex:0] == 'h' && [name characterAtIndex:1] >= '1' &&
        [name characterAtIndex:1] <= '6';
    if (end) {
        if ([name isEqual:@"a"]) CloseAnchor();
        if ([name isEqual:@"pre"]) pre = MAX(0, pre - 1);
        if (heading || [name isEqual:@"pre"] || [paragraphs containsObject:name]) Block(2);
        else if ([lines containsObject:name]) Block(1);
        return;
    }
    if ([name isEqual:@"title"]) {
        NSString* text = SkipRaw(name);
        if (!title.length) {
            std::vector<unichar> chars(text.length);
            [text getCharacters:chars.data() range:NSMakeRange(0, text.length)];
            title = Collapsed(Decoded(chars, 0, chars.size()), 300);
        }
        return;
    }
    // "<script/>" still opens a script in HTML, as browsers read it, so its text stays hidden here too; only SVG and
    // MathML elements may close themselves.
    if ([raw containsObject:name]) {
        scripts = scripts || [name isEqual:@"script"];
        SkipRaw(name);
        return;
    }
    BOOL foreign = [name isEqual:@"svg"] || [name isEqual:@"math"];
    if ([nested containsObject:name]) { if (!(selfClosing && foreign)) SkipNested(name); return; }
    if ([name isEqual:@"base"]) {
        NSURL* URL = href && !baseSet ? [NSURL URLWithString:href relativeToURL:base].absoluteURL : nil;
        if ([URL.scheme.lowercaseString isEqual:@"https"]) base = URL;
        baseSet = baseSet || href;
        return;
    }
    if ([name isEqual:@"a"]) {
        CloseAnchor();
        NSURL* URL = href.length ? [NSURL URLWithString:href relativeToURL:base].absoluteURL : nil;
        if ([URL.scheme.lowercaseString isEqual:@"https"] && URL.host.length && URL.absoluteString.length <= 2048) {
            anchor = URL.absoluteString;
            anchorStart = out.size();
        }
        return;
    }
    if (heading) {
        Block(2);
        Prefix([@"######" substringToIndex:[name characterAtIndex:1] - '0']);
        pendingSpace = YES;
        return;
    }
    if ([name isEqual:@"li"]) { Block(1); Prefix(@"-"); pendingSpace = YES; return; }
    if ([name isEqual:@"td"] || [name isEqual:@"th"]) { if (!out.empty() && !pendingBreak) pendingCell = YES; return; }
    if ([name isEqual:@"br"]) { if (!out.empty()) pendingBreak = MIN(pendingBreak + 1, 2); return; }
    if ([name isEqual:@"pre"]) { Block(2); pre++; return; }
    if ([paragraphs containsObject:name]) Block(2);
    else if ([lines containsObject:name]) Block(1);
}

SPDFMacAIWebReadable* SPDFMacAIWebReadableText(NSData* body, NSString* contentType, NSURL* baseURL,
                                               NSUInteger maxTextBytes, NSError** error) {
    if (error) *error = nil;
    NSString* type = [[contentType componentsSeparatedByString:@";"].firstObject
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    NSArray* markupTypes = @[@"text/html", @"application/xhtml+xml", @"application/xml", @"text/xml",
                             @"application/rss+xml", @"application/atom+xml"];
    BOOL html = [markupTypes containsObject:type];
    BOOL plain = !html && ([type hasPrefix:@"text/"] || [type isEqual:@"application/json"] ||
                           [type hasSuffix:@"+json"]);
    if (!type.length) {
        // No declared type: markup if it starts like markup, text if it has no NUL bytes, otherwise neither.
        NSData* head = [body subdataWithRange:NSMakeRange(0, MIN(body.length, (NSUInteger)1024))];
        NSString* prefix = [[[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        html = [prefix hasPrefix:@"<"];
        plain = !html && memchr(head.bytes, 0, head.length) == NULL;
    }
    if (!html && !plain) {
        if (error) *error = SPDFMacAIWebMakeError(SPDFMacAIWebErrorUnsupportedContent, [NSString stringWithFormat:
            @"The page is %@, not text open_page can read.", type.length ? type : @"binary data"]);
        return nil;
    }
    NSString* text = SPDFMacAIWebDecodeText(body, contentType, html);
    if (!html) text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    Extractor extractor;
    extractor.s.resize(text.length);
    [text getCharacters:extractor.s.data() range:NSMakeRange(0, text.length)];
    extractor.limit = maxTextBytes;
    extractor.base = baseURL;
    extractor.markup = html;
    extractor.pre = html ? 0 : 1;
    extractor.Run();
    NSString* readable = [NSString stringWithCharacters:extractor.out.data() length:extractor.out.size()];
    readable = [readable stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    SPDFMacAIWebReadable* page = [[SPDFMacAIWebReadable alloc] initWithTitle:extractor.title text:readable
                                                                   truncated:extractor.truncated links:extractor.links];
    page.markup = html;
    page.scripts = extractor.scripts;
    return page;
}

BOOL SPDFMacAIWebHasPasswordField(NSData* body) {
    NSString* text = [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding];
    for (NSString* spelling in @[@"type=\"password\"", @"type='password'", @"type=password"])
        if ([text rangeOfString:spelling options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}
