// Links in a friend's message: a click shows where the link goes in a small menu, and only the menu opens it.
//
// WHY a menu rather than opening on click: a link's words are the sender's, and Markdown lets them show one address
// while the link goes to another ("[https://www.apple.com](https://login.example.net)"). A tooltip naming the
// destination appears only after a hover delay, so a quick click opened the other site. A link the host draws itself
// (in a table) comes to the same menu through SZFriendsShowLinkMenuInView (SZFriendsHost.h).

#import "mac/SZFriendsItemViewsInternal.h"

// Longer addresses lose the end of their path in the menu, never their host.
static const NSUInteger SZFLinkTitleLength = 80;

BOOL SZFriendsLinkMayOpen(NSURL *url) {
    // As SZFriendsRichText: a friend's message must not open file: or app-scheme URLs, whatever the host rendered.
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"mailto"];
}

static BOOL SZFIsMail(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"mailto"];
}

// The address a mailto: link writes to, without its ?subject=... part.
static NSString *SZFMailAddress(NSURL *url) {
    NSString *rest = url.resourceSpecifier ?: @"";
    NSRange query = [rest rangeOfString:@"?"];
    if (query.location != NSNotFound) rest = [rest substringToIndex:query.location];
    return (rest.stringByRemovingPercentEncoding ?: rest).lowercaseString;
}

// A host as compared: lowercase, in the spelling NSURL keeps (so an internationalized name compares in one form),
// without a final dot or a leading "www.", which nobody reads as a different site.
static NSString *SZFHostKey(NSString *host) {
    if (!host.length) return nil;
    NSURL *probe = [NSURL URLWithString:[@"https://" stringByAppendingString:host]];
    NSString *key = (probe.host.length ? probe.host : host).lowercaseString;
    while ([key hasSuffix:@"."]) key = [key substringToIndex:key.length - 1];
    if ([key hasPrefix:@"www."]) key = [key substringFromIndex:4];
    return key.length ? key : nil;
}

// YES when `destination` is the shown site or a part of it (support.apple.com for apple.com): only the owner of a
// domain controls its subdomains, while apple.com.example.net belongs to example.net.
static BOOL SZFSameSite(NSString *destination, NSString *shown) {
    NSString *to = SZFHostKey(destination), *from = SZFHostKey(shown);
    if (!to || !from) return NO;
    return [to isEqualToString:from] || [to hasSuffix:[@"." stringByAppendingString:from]];
}

// A bare name reads as a site only with a common web ending: "apple.com" does, "report.pdf" and "README.md" are
// file names people link to their files, and a warning on those would teach people to ignore the warning.
static BOOL SZFLooksLikeSite(NSString *host, BOOL bare) {
    NSArray<NSString *> *labels = [host.lowercaseString componentsSeparatedByString:@"."];
    if (labels.count < 2 || host.length > 253) return NO;
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-"];
    for (NSString *label in labels)
        if (!label.length || [label rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    NSString *ending = labels.lastObject;
    if (!bare) return ending.length >= 2;
    static NSSet<NSString *> *endings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        endings = [NSSet setWithArray:@[ @"com", @"net", @"org", @"io", @"co", @"app", @"dev", @"ai", @"gov", @"edu",
                                         @"info", @"biz", @"me", @"xyz", @"online", @"site", @"shop", @"cn", @"hk",
                                         @"tw", @"jp", @"sg", @"uk", @"de", @"fr", @"us" ]];
    });
    return [endings containsObject:ending] || [ending hasPrefix:@"xn--"];
}

// What a link's words present as where it goes: a host ("www.apple.com" from "https://www.apple.com/account", or
// "apple.com"), or an email address (*mail YES); nil for ordinary words ("the plan").
static NSString *SZFShownAddress(NSString *text, BOOL *mail) {
    NSMutableCharacterSet *edges = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [edges addCharactersInString:@"<>()[]\"'“”‘’.,;:!?"];
    NSString *words = [text stringByTrimmingCharactersInSet:edges];
    *mail = NO;
    if (!words.length || words.length > 2048 ||
        [words rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound)
        return nil;
    BOOL addressed = NO; // the words name a scheme or start with www., so they are meant as an address
    if ([words.lowercaseString hasPrefix:@"mailto:"]) {
        words = [words substringFromIndex:7];
        addressed = YES;
    }
    NSRange scheme = [words rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        NSString *host = [NSURL URLWithString:words].host;
        if (host.length) return host.lowercaseString;
        words = [words substringFromIndex:NSMaxRange(scheme)];
        addressed = YES;
    }
    NSRange end = [words rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#"]];
    NSString *head = end.location == NSNotFound ? words : [words substringToIndex:end.location];
    NSRange at = [head rangeOfString:@"@" options:NSBackwardsSearch];
    if (at.location != NSNotFound && at.location > 0) {
        NSString *domain = [head substringFromIndex:NSMaxRange(at)];
        if (!SZFLooksLikeSite(domain, NO)) return nil;
        *mail = YES;
        return head.lowercaseString;
    }
    NSRange port = [head rangeOfString:@":"];
    if (port.location != NSNotFound) head = [head substringToIndex:port.location];
    addressed = addressed || [head.lowercaseString hasPrefix:@"www."];
    return SZFLooksLikeSite(head, !addressed) ? head.lowercaseString : nil;
}

NSString *SZFriendsLinkShownElsewhere(NSString *text, NSURL *url) {
    BOOL shownMail = NO;
    NSString *shown = SZFShownAddress(text ?: @"", &shownMail);
    if (!shown || !url) return nil;
    NSString *shownSite = shownMail ? [shown substringFromIndex:NSMaxRange([shown rangeOfString:@"@"
                                                                                          options:NSBackwardsSearch])]
                                    : shown;
    if (SZFIsMail(url)) {
        NSString *address = SZFMailAddress(url);
        if (shownMail) return [address isEqualToString:shown] ? nil : shown;
        NSRange at = [address rangeOfString:@"@" options:NSBackwardsSearch];
        NSString *domain = at.location == NSNotFound ? @"" : [address substringFromIndex:NSMaxRange(at)];
        return SZFSameSite(domain, shownSite) ? nil : shown;
    }
    return SZFSameSite(url.host, shownSite) ? nil : shown;
}

NSString *SZFriendsLinkAddressTitle(NSURL *url) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *full = parts.string ?: url.absoluteString ?: @"";
    if (full.length <= SZFLinkTitleLength) return full;
    NSRange host = parts.rangeOfPort.location != NSNotFound ? parts.rangeOfPort : parts.rangeOfHost;
    NSUInteger keep = MAX(host.location == NSNotFound ? 0 : NSMaxRange(host), SZFLinkTitleLength - 1);
    NSRange kept = [full rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN(keep, full.length))];
    return [[full substringWithRange:kept] stringByAppendingString:@"…"];
}

// The menu's action target. A menu item holds its target weakly, so each item that opens also keeps this as its
// represented object.
@interface SZFLinkOpener : NSObject
@property(nonatomic, weak) SZFriendsContext *context;
@property(nonatomic, strong) NSURL *url;
@end

@implementation SZFLinkOpener
- (void)open:(id)sender {
    (void)sender;
    SZFriendsContext *context = self.context;
    if (SZFriendsLinkMayOpen(self.url) && context.openURL) context.openURL(self.url);
}
@end

NSMenu *SZFriendsLinkMenu(SZFriendsContext *context, NSURL *url, NSString *text) {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO; // the address lines inform, only the open item acts
    SZFLinkOpener *opener = [SZFLinkOpener new];
    opener.context = context;
    opener.url = url;
    NSString *shown = SZFriendsLinkShownElsewhere(text, url);
    NSString *elsewhere = [context string:@"link_elsewhere"];
    if (shown && elsewhere.length) {
        NSString *destination = (SZFIsMail(url) ? SZFMailAddress(url) : url.host.lowercaseString) ?: @"";
        // The friend's words go in last, so nothing in them is read as a placeholder.
        NSString *title = [[elsewhere stringByReplacingOccurrencesOfString:@"{host}" withString:destination]
            stringByReplacingOccurrencesOfString:@"{shown}" withString:shown];
        NSMenuItem *warning = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
        warning.enabled = NO;
        NSImage *caution = [[NSImage imageNamed:NSImageNameCaution] copy];
        caution.size = NSMakeSize(14, 14);
        warning.image = caution;
    }
    NSMenuItem *address = [menu addItemWithTitle:SZFriendsLinkAddressTitle(url) action:nil keyEquivalent:@""];
    NSString *openTitle = [context string:SZFIsMail(url) ? @"link_open_email" : @"link_open"];
    NSMenuItem *open = address;
    if (openTitle.length) {
        address.enabled = NO;
        open = [menu addItemWithTitle:openTitle action:nil keyEquivalent:@""];
    }
    // Without the catalog's words the address itself opens the link: views never invent text (PROTOCOL.md § Static
    // strings), and the destination is still what the person reads and chooses.
    open.action = @selector(open:);
    open.target = opener;
    open.representedObject = opener;
    open.enabled = YES;
    return menu;
}

void SZFriendsShowLinkMenu(SZFriendsContext *context, id link, NSTextView *textView, NSUInteger charIndex) {
    NSURL *url = [link isKindOfClass:NSURL.class]      ? link
                 : [link isKindOfClass:NSString.class] ? [NSURL URLWithString:link]
                                                       : nil;
    if (!context || !url || !SZFriendsLinkMayOpen(url)) return;
    NSTextStorage *storage = textView.textStorage;
    NSString *words = @"";
    NSPoint point = NSZeroPoint;
    if (charIndex < storage.length) {
        NSRange range = NSMakeRange(charIndex, 1);
        [storage attribute:NSLinkAttributeName atIndex:charIndex longestEffectiveRange:&range
                   inRange:NSMakeRange(0, storage.length)];
        words = [storage.string substringWithRange:range];
        // Under the link's first line, where the person is looking (a text view is flipped).
        NSLayoutManager *layout = textView.layoutManager;
        NSRange glyphs = [layout glyphRangeForCharacterRange:NSMakeRange(charIndex, 1) actualCharacterRange:NULL];
        NSRect rect = [layout boundingRectForGlyphRange:glyphs inTextContainer:textView.textContainer];
        NSPoint origin = textView.textContainerOrigin;
        point = NSMakePoint(NSMinX(rect) + origin.x, NSMaxY(rect) + origin.y);
    }
    if (context.presentMenu) context.presentMenu(SZFriendsLinkMenu(context, url, words), textView, point);
}

void SZFriendsShowLinkMenuInView(NSView *view, NSURL *url, NSString *words, NSPoint point) {
    // The bubble the click landed in: its text view, a wide block's strip, or a view inside either.
    SZFriendsMessageBody *body = nil;
    for (NSView *ancestor = view; ancestor && !body; ancestor = ancestor.superview)
        if ([ancestor isKindOfClass:SZFriendsMessageBody.class]) body = (SZFriendsMessageBody *)ancestor;
    SZFriendsContext *context = body.context;
    if (!context || ![url isKindOfClass:NSURL.class] || !SZFriendsLinkMayOpen(url)) return;
    NSString *shown = [words isKindOfClass:NSString.class] ? words : @"";
    if (context.presentMenu) context.presentMenu(SZFriendsLinkMenu(context, url, shown), view, point);
}
