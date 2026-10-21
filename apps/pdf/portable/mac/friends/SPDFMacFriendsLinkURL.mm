// The strict check of shenzhenpdf://friends/link#<payload> (SPDFMacFriendsLinkURL.h). It works on the URL's bytes,
// never on NSURL's parsing, so a percent-escape, a second '#', a query or a host spelled differently cannot slip a
// different payload past it.

#import "SPDFMacFriendsLinkURL.h"

#include <string>
#include <vector>

const NSUInteger SPDFMacFriendsLinkMaxBytes = 512;

namespace {

int Base64URLValue(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

// Unpadded base64url that decodes canonically: no '=', no length of 1 mod 4, and unused trailing bits zero, so
// exactly one spelling of each payload exists.
bool DecodeCanonical(const std::string& text, std::vector<unsigned char>& out) {
    if (text.empty() || text.size() % 4 == 1) return false;
    uint32_t buffer = 0;
    int bits = 0;
    for (unsigned char c : text) {
        int value = Base64URLValue(c);
        if (value < 0) return false;
        buffer = (buffer << 6) | (uint32_t)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back((unsigned char)((buffer >> bits) & 0xff));
        }
    }
    return (buffer & ((1u << bits) - 1)) == 0;
}

// Lowercase ASCII words joined by single hyphens, 3 to 64 bytes (a Friends ID).
bool IsFriendsID(const unsigned char* bytes, size_t length) {
    if (length < 3 || length > 64 || bytes[0] == '-' || bytes[length - 1] == '-') return false;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = bytes[i];
        if (c == '-') {
            if (bytes[i - 1] == '-') return false;
        } else if (c < 'a' || c > 'z') {
            return false;
        }
    }
    return true;
}

// Valid UTF-8 without control characters (C0, DEL, C1): the name a person chose, shown as plain text.
bool IsPlainName(const unsigned char* bytes, size_t length) {
    NSString* name = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!name) return false;
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c < 0x20 || (c >= 0x7f && c <= 0x9f)) return false;
    }
    return true;
}

SPDFMacFriendsLinkRefusal CheckLayout(char kind, const std::vector<unsigned char>& bytes) {
    if (bytes.empty() || bytes[0] != 0x01) return SPDFMacFriendsLinkWrongType;
    if (kind == 'd') return bytes.size() == 1 + 16 + 32 ? SPDFMacFriendsLinkAccepted : SPDFMacFriendsLinkWrongType;
    size_t at = 1 + 32 + 16;
    if (bytes.size() < at + 1) return SPDFMacFriendsLinkWrongType;
    size_t idLength = bytes[at++];
    if (bytes.size() < at + idLength + 1 || !IsFriendsID(bytes.data() + at, idLength))
        return SPDFMacFriendsLinkWrongType;
    at += idLength;
    size_t nameLength = bytes[at++];
    if (nameLength > 160 || bytes.size() != at + nameLength || !IsPlainName(bytes.data() + at, nameLength))
        return SPDFMacFriendsLinkWrongType;
    return SPDFMacFriendsLinkAccepted;
}

}  // namespace

NSString* SPDFMacFriendsLinkPayloadFromString(NSString* text, NSString* scheme, SPDFMacFriendsLinkRefusal* refusal) {
    SPDFMacFriendsLinkRefusal ignored;
    if (!refusal) refusal = &ignored;
    *refusal = SPDFMacFriendsLinkNotOurs;
    if (![text isKindOfClass:NSString.class] || !scheme.length) return nil;
    const char* utf8 = text.UTF8String;
    if (!utf8) return nil;
    std::string url(utf8);
    std::string own = std::string(scheme.lowercaseString.UTF8String) + ":";
    if (url.size() < own.size()) return nil;
    for (size_t i = 0; i < own.size(); i++)
        if (tolower((unsigned char)url[i]) != own[i]) return nil;
    NSUInteger byteLength = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteLength > SPDFMacFriendsLinkMaxBytes) {
        *refusal = SPDFMacFriendsLinkOversized;
        return nil;
    }
    *refusal = SPDFMacFriendsLinkMalformed;
    // A NUL inside the text would end the C string early and hide whatever follows it.
    if (url.size() != byteLength) return nil;
    const std::string rest = "//friends/link#";
    if (url.compare(own.size(), rest.size(), rest) != 0) return nil;
    std::string payload = url.substr(own.size() + rest.size());
    if (payload.size() < 3) return nil;
    if (payload[1] != '.') return nil;
    std::vector<unsigned char> bytes;
    if (!DecodeCanonical(payload.substr(2), bytes)) return nil;
    char kind = payload[0];
    if (kind != 'f' && kind != 'd') {
        *refusal = SPDFMacFriendsLinkWrongType;
        return nil;
    }
    *refusal = CheckLayout(kind, bytes);
    return *refusal == SPDFMacFriendsLinkAccepted ? @(payload.c_str()) : nil;
}

NSString* SPDFMacFriendsLinkPayload(NSURL* url, NSString* scheme, SPDFMacFriendsLinkRefusal* refusal) {
    return SPDFMacFriendsLinkPayloadFromString(url.absoluteString, scheme, refusal);
}

NSString* SPDFMacFriendsRouteFromString(NSString* text, NSString* scheme) {
    if (![text isKindOfClass:NSString.class] || !scheme.length) return nil;
    const char* utf8 = text.UTF8String;
    if (!utf8) return nil;
    std::string url(utf8);
    NSUInteger byteLength = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteLength > SPDFMacFriendsLinkMaxBytes || url.size() != byteLength) return nil;
    std::string own = std::string(scheme.lowercaseString.UTF8String) + ":";
    if (url.size() < own.size()) return nil;
    for (size_t i = 0; i < own.size(); i++)
        if (tolower((unsigned char)url[i]) != own[i]) return nil;
    std::string rest = url.substr(own.size());
    if (rest == "//friends" || rest == "//friends/") return @"";
    const std::string prefix = "//friends/conversation/";
    if (rest.compare(0, prefix.size(), prefix) != 0) return nil;
    std::string conversation = rest.substr(prefix.size());
    if (conversation.empty() || conversation.size() > 64) return nil;
    for (unsigned char c : conversation)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'))
            return nil;
    return @(conversation.c_str());
}

void SPDFMacFriendsSortOpenedURLsWithRoutes(NSArray<NSURL*>* urls, NSString* scheme, NSMutableArray<NSString*>* paths,
                                            NSMutableArray<NSString*>* payloads, NSMutableArray<NSString*>* routes) {
    for (NSURL* url in urls) {
        if (![url isKindOfClass:NSURL.class]) continue;
        if (url.isFileURL) {
            if (url.path.length) [paths addObject:url.path];
            continue;
        }
        NSString* payload = SPDFMacFriendsLinkPayload(url, scheme, NULL);
        if (payload) [payloads addObject:payload];
        NSString* route = routes ? SPDFMacFriendsRouteFromString(url.absoluteString, scheme) : nil;
        if (route) [routes addObject:route];
    }
}

void SPDFMacFriendsSortOpenedURLs(NSArray<NSURL*>* urls, NSString* scheme, NSMutableArray<NSString*>* paths,
                                  NSMutableArray<NSString*>* payloads) {
    SPDFMacFriendsSortOpenedURLsWithRoutes(urls, scheme, paths, payloads, nil);
}
