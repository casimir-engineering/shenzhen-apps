#import "SPDFMacChatMarkdownParts.h"

// Links inside drawn tables. A cell's words are the sender's, and Markdown lets them show one address while the link
// goes to another ("[https://www.apple.com](https://login.example.net)"), so a click never opens: it shows where the
// link goes, with a warning when the words name another site, and only the menu's last item opens it. A host with
// its own menu (Friends) takes the click instead through options.linkHandler. The rules for what counts as showing
// another site match Friends' bubble links (portable/friends/mac/SZFriendsLinkMenu.m), so both menus agree.

// Longer addresses lose the end of their path in the menu, never their host.
static const NSUInteger kAddressTitleLength = 80;

// A host as compared: lowercase, in the spelling NSURL keeps (an internationalised name compares in one form), without
// a final dot or a leading "www.", which nobody reads as a different site.
static NSString* HostKey(NSString* host) {
    if (!host.length) return nil;
    NSURL* probe = [NSURL URLWithString:[@"https://" stringByAppendingString:host]];
    NSString* key = (probe.host.length ? probe.host : host).lowercaseString;
    while ([key hasSuffix:@"."]) key = [key substringToIndex:key.length - 1];
    if ([key hasPrefix:@"www."]) key = [key substringFromIndex:4];
    return key.length ? key : nil;
}

// YES when `destination` is the shown site or part of it (support.apple.com for apple.com): only a domain's owner
// controls its subdomains, while apple.com.example.net belongs to example.net.
static BOOL SameSite(NSString* destination, NSString* shown) {
    NSString *to = HostKey(destination), *from = HostKey(shown);
    if (!to || !from) return NO;
    return [to isEqualToString:from] || [to hasSuffix:[@"." stringByAppendingString:from]];
}

// A bare name reads as a site only with a common web ending: "apple.com" does, while "report.pdf" and "README.md"
// are file names, and warning on those would teach people to ignore the warning.
static BOOL LooksLikeSite(NSString* host, BOOL bare) {
    NSArray<NSString*>* labels = [host.lowercaseString componentsSeparatedByString:@"."];
    if (labels.count < 2 || host.length > 253) return NO;
    NSMutableCharacterSet* allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-"];
    for (NSString* label in labels)
        if (!label.length || [label rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    NSString* ending = labels.lastObject;
    if (!bare) return ending.length >= 2;
    static NSSet<NSString*>* endings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      endings = [NSSet setWithArray:@[ @"com", @"net", @"org", @"io", @"co", @"app", @"dev", @"ai", @"gov", @"edu",
                                       @"info", @"biz", @"me", @"xyz", @"online", @"site", @"shop", @"cn", @"hk", @"tw",
                                       @"jp", @"sg", @"uk", @"de", @"fr", @"us" ]];
    });
    return [endings containsObject:ending] || [ending hasPrefix:@"xn--"];
}

// What the words present as where the link goes: a host, or an email address (*mail YES); nil for ordinary words.
static NSString* ShownAddress(NSString* text, BOOL* mail) {
    NSMutableCharacterSet* edges = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [edges addCharactersInString:@"<>()[]\"'“”‘’.,;:!?"];
    NSString* words = [text stringByTrimmingCharactersInSet:edges];
    *mail = NO;
    if (!words.length || words.length > 2048 ||
        [words rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return nil;
    BOOL addressed = NO;  // the words name a scheme or start with www., so they are meant as an address
    if ([words.lowercaseString hasPrefix:@"mailto:"]) {
        words = [words substringFromIndex:7];
        addressed = YES;
    }
    NSRange scheme = [words rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        NSString* host = [NSURL URLWithString:words].host;
        if (host.length) return host.lowercaseString;
        words = [words substringFromIndex:NSMaxRange(scheme)];
        addressed = YES;
    }
    NSRange end = [words rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    NSString* head = end.location == NSNotFound ? words : [words substringToIndex:end.location];
    NSRange at = [head rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound && at.location > 0) {
        if (!LooksLikeSite([head substringFromIndex:NSMaxRange(at)], NO)) return nil;
        *mail = YES;
        return head.lowercaseString;
    }
    NSRange port = [head rangeOfString:@":"];
    if (port.location != NSNotFound) head = [head substringToIndex:port.location];
    addressed = addressed || [head.lowercaseString hasPrefix:@"www."];
    return LooksLikeSite(head, !addressed) ? head.lowercaseString : nil;
}

NSString* SPDFMacChatLinkShownElsewhere(NSString* shownText, NSURL* URL) {
    BOOL mail = NO;
    NSString* shown = ShownAddress(shownText ?: @"", &mail);
    if (!shown || !URL.host.length) return nil;
    NSString* site = mail ? [shown substringFromIndex:NSMaxRange([shown rangeOfString:@"@"
                                                                              options:NSBackwardsSearch])]
                          : shown;
    return SameSite(URL.host, site) ? nil : shown;
}

static NSString* AddressTitle(NSURL* URL) {
    NSURLComponents* parts = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSString* full = parts.string ?: URL.absoluteString ?: @"";
    if (full.length <= kAddressTitleLength) return full;
    NSRange host = parts.rangeOfPort.location != NSNotFound ? parts.rangeOfPort : parts.rangeOfHost;
    NSUInteger keep = MAX(host.location == NSNotFound ? 0 : NSMaxRange(host), kAddressTitleLength - 1);
    NSRange kept = [full rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN(keep, full.length))];
    return [[full substringWithRange:kept] stringByAppendingString:@"…"];
}

@interface NSWorkspace (SPDFMacChatMarkdown)
- (void)spdf_open:(NSMenuItem*)item;
@end
@implementation NSWorkspace (SPDFMacChatMarkdown)
- (void)spdf_open:(NSMenuItem*)item {
    if ([item.representedObject isKindOfClass:NSURL.class]) [self openURL:item.representedObject];
}
@end

NSMenu* SPDFMacChatLinkMenu(NSURL* URL, NSString* shownText) {
    NSMenu* menu = [NSMenu new];
    menu.autoenablesItems = NO;  // the address lines inform, only Open in Browser acts
    NSString* shown = SPDFMacChatLinkShownElsewhere(shownText, URL);
    if (shown) {
        NSString* title = [NSString stringWithFormat:@"Goes to %@, not %@", URL.host.lowercaseString, shown];
        NSMenuItem* warning = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
        warning.enabled = NO;
        NSImage* caution = [[NSImage imageNamed:NSImageNameCaution] copy];
        caution.size = NSMakeSize(14, 14);
        warning.image = caution;
    }
    [menu addItemWithTitle:AddressTitle(URL) action:nil keyEquivalent:@""].enabled = NO;
    NSMenuItem* open = [menu addItemWithTitle:@"Open in Browser" action:@selector(spdf_open:) keyEquivalent:@""];
    open.representedObject = URL;
    open.target = NSWorkspace.sharedWorkspace;
    return menu;
}

BOOL SPDFMacChatOpenBlockLink(NSURL* URL, NSString* shownText, SPDFMacChatMarkdownOptions* options, NSView* view,
                              NSPoint point) {
    if (options.linkHandler && view) {
        options.linkHandler(URL, shownText ?: @"", view, point);
        return YES;
    }
    if (options.openLink) {
        options.openLink(URL);
        return YES;
    }
    if (!view || ![URL.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    [SPDFMacChatLinkMenu(URL, shownText ?: @"") popUpMenuPositioningItem:nil atLocation:point inView:view];
    return YES;
}
