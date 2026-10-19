// Links in ShenzhenPDF (portable/friends/PROTOCOL.md § Links): the strict check of shenzhenpdf://friends/link#…, the
// scheme in Info.plist, the Copy Download Link menus, and the drop panel's "Copy link instead" through the host.
//
// Usage: SPDFMacFriendsLinkTests <Info.plist>

#import <AppKit/AppKit.h>
#import "SPDFMacFriendsHost.h"
#import "SPDFMacFriendsLinkURL.h"
#import "SPDFMacFriendsShareMenu.h"
#import "SPDFMacFriendsTestSupport.h"

#include <string>
#include <vector>

static NSString* Base64URL(const std::vector<unsigned char>& bytes) {
    NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    NSString* text = [data base64EncodedStringWithOptions:0];
    text = [text stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    text = [text stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [text stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static std::vector<unsigned char> DownloadBytes() {
    std::vector<unsigned char> bytes(49, 0x5a);
    bytes[0] = 0x01;
    return bytes;
}

static std::vector<unsigned char> FriendBytes(const std::string& friendsID, const std::string& name) {
    std::vector<unsigned char> bytes(1 + 32 + 16, 0x33);
    bytes[0] = 0x01;
    bytes.push_back((unsigned char)friendsID.size());
    bytes.insert(bytes.end(), friendsID.begin(), friendsID.end());
    bytes.push_back((unsigned char)name.size());
    bytes.insert(bytes.end(), name.begin(), name.end());
    return bytes;
}

static NSString* LinkURL(NSString* payload) {
    return [@"shenzhenpdf://friends/link#" stringByAppendingString:payload];
}

static void ExpectRefused(NSString* text, SPDFMacFriendsLinkRefusal expected, NSString* why) {
    SPDFMacFriendsLinkRefusal refusal = SPDFMacFriendsLinkAccepted;
    NSString* payload = SPDFMacFriendsLinkPayloadFromString(text, @"shenzhenpdf", &refusal);
    Expect(payload == nil && refusal == expected, @"%@ (%@): refusal %ld, expected %ld", why, text, (long)refusal,
           (long)expected);
}

static void TestPayloads(void) {
    NSString* download = [@"d." stringByAppendingString:Base64URL(DownloadBytes())];
    NSString* friendLink = [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", "Mei Lin"))];
    SPDFMacFriendsLinkRefusal refusal = SPDFMacFriendsLinkNotOurs;
    NSString* passed = SPDFMacFriendsLinkPayloadFromString(LinkURL(download), @"shenzhenpdf", &refusal);
    Expect([passed isEqualToString:download] &&
               refusal == SPDFMacFriendsLinkAccepted,
           @"a download link passes");
    Expect([SPDFMacFriendsLinkPayload([NSURL URLWithString:LinkURL(friendLink)], @"shenzhenpdf", NULL)
               isEqualToString:friendLink],
           @"a friend link passes through NSURL as it arrives");
    NSString* upper = [@"ShenzhenPDF://friends/link#" stringByAppendingString:download];
    Expect([SPDFMacFriendsLinkPayloadFromString(upper, @"shenzhenpdf", NULL) isEqualToString:download],
           @"schemes are case-insensitive");
    NSString* empty = [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", ""))];
    Expect(SPDFMacFriendsLinkPayloadFromString(LinkURL(empty), @"shenzhenpdf", NULL) != nil, @"no name");
    NSString* longest =
        [@"f." stringByAppendingString:Base64URL(FriendBytes(std::string(64, 'a'), std::string(160, 'z')))];
    Expect(SPDFMacFriendsLinkPayloadFromString(LinkURL(longest), @"shenzhenpdf", NULL) != nil, @"the longest");

    // Not ours: the app's other URLs go elsewhere untouched.
    ExpectRefused(@"file:///Users/raph/a.pdf", SPDFMacFriendsLinkNotOurs, @"a document");
    ExpectRefused([@"shenzhenfiles://friends/link#" stringByAppendingString:download], SPDFMacFriendsLinkNotOurs,
                  @"the other app's scheme");
    ExpectRefused(nil, SPDFMacFriendsLinkNotOurs, @"nothing");

    // Oversized: refused before anything is decoded, at 513 bytes.
    NSString* padded = [LinkURL(download) stringByPaddingToLength:513 withString:@"A" startingAtIndex:0];
    ExpectRefused(padded, SPDFMacFriendsLinkOversized, @"513 bytes");
    ExpectRefused([LinkURL(download) stringByPaddingToLength:4096 withString:@"A" startingAtIndex:0],
                  SPDFMacFriendsLinkOversized, @"4 KiB");

    // Malformed: anything but exactly //friends/link#<kind>.<canonical base64url>.
    NSString* body = [download substringFromIndex:2];
    NSArray* malformed = @[
        [@"shenzhenpdf://friend/link#" stringByAppendingString:download], [@"shenzhenpdf://Friends/link#"
            stringByAppendingString:download], [@"shenzhenpdf://friends/link/#" stringByAppendingString:download],
        [@"shenzhenpdf://friends/link?x=1#" stringByAppendingString:download],
        [@"shenzhenpdf://friends:80/link#" stringByAppendingString:download],
        [@"shenzhenpdf://mei@friends/link#" stringByAppendingString:download], [@"shenzhenpdf:friends/link#"
            stringByAppendingString:download], @"shenzhenpdf://friends/link", @"shenzhenpdf://friends/link#",
        LinkURL(@"d."), LinkURL([download stringByAppendingString:@"#"]),
        LinkURL([download stringByAppendingString:@"="]),
        LinkURL([@"d.%41" stringByAppendingString:[body substringFromIndex:1]]),
        LinkURL([download stringByReplacingCharactersInRange:NSMakeRange(5, 1) withString:@"+"]),
        LinkURL([download stringByAppendingString:@"AAA"]),  // a length of 1 mod 4
        LinkURL([download stringByReplacingCharactersInRange:NSMakeRange(download.length - 1, 1) withString:@"z"]),
        LinkURL([download stringByAppendingString:[NSString stringWithFormat:@"%CAAAA", (unichar)0]]),
        LinkURL(@"dd"), LinkURL([@"d:" stringByAppendingString:body]),
    ];
    for (NSString* text in malformed) ExpectRefused(text, SPDFMacFriendsLinkMalformed, @"malformed");

    // Wrong type: another kind, or bytes without that kind's layout.
    std::vector<unsigned char> shortDownload = DownloadBytes();
    shortDownload.pop_back();
    std::vector<unsigned char> version2 = DownloadBytes();
    version2[0] = 0x02;
    std::vector<unsigned char> trailing = FriendBytes("brave-otter", "Mei");
    trailing.push_back('x');
    NSArray* wrong = @[
        [@"x." stringByAppendingString:body], [@"F." stringByAppendingString:body],
        [@"f." stringByAppendingString:body],  // a download's bytes as a friend link
        [@"d." stringByAppendingString:Base64URL(FriendBytes("brave-otter", "Mei"))],
        [@"d." stringByAppendingString:Base64URL(shortDownload)], [@"d." stringByAppendingString:Base64URL(version2)],
        [@"f." stringByAppendingString:Base64URL(trailing)],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("Brave-Otter", "Mei"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("brave--otter", "Mei"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("-brave", "Mei"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("ab", "Mei"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", "Mei\nOpen this"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", "Mei\xc2\x85"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", "\xff\xfe"))],
        [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", std::string(161, 'z')))],
    ];
    for (NSString* payload in wrong) ExpectRefused(LinkURL(payload), SPDFMacFriendsLinkWrongType, @"wrong type");
}

// The one rule for download payloads, shared with the link page and the helper (run from portable/).
static void TestSharedDownloadPayloads(void) {
    NSData* json = [NSData dataWithContentsOfFile:@"friends/service/links/tests/download-payloads.json"];
    NSDictionary* fixture = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : nil;
    Expect([fixture[@"accepted"] count] > 0 && [fixture[@"refused"] count] > 0, @"the fixture is there");
    for (NSString* payload in fixture[@"accepted"]) {
        Expect([SPDFMacFriendsLinkPayloadFromString(LinkURL(payload), @"shenzhenpdf", NULL) isEqual:payload],
               @"refused %@", payload);
    }
    for (NSDictionary* refused in fixture[@"refused"]) {
        Expect(SPDFMacFriendsLinkPayloadFromString(LinkURL(refused[@"payload"]), @"shenzhenpdf", NULL) == nil,
               @"accepted: %@", refused[@"why"]);
    }
}

static void TestSorting(void) {
    NSString* download = [@"d." stringByAppendingString:Base64URL(DownloadBytes())];
    NSString* friendLink = [@"f." stringByAppendingString:Base64URL(FriendBytes("brave-otter", "Mei"))];
    NSArray* urls = @[
        [NSURL fileURLWithPath:@"/Users/raph/Documents/a.pdf"], [NSURL URLWithString:LinkURL(download)],
        [NSURL URLWithString:@"https://example.com/d#x"], [NSURL URLWithString:@"shenzhenpdf://friends/link#d.AAAA"],
        [NSURL fileURLWithPath:@"/Users/raph/Documents/b.md"], [NSURL URLWithString:LinkURL(friendLink)],
    ];
    NSMutableArray* paths = [NSMutableArray array], *payloads = [NSMutableArray array];
    SPDFMacFriendsSortOpenedURLs(urls, @"shenzhenpdf", paths, payloads);
    Expect([paths isEqualToArray:(@[ @"/Users/raph/Documents/a.pdf", @"/Users/raph/Documents/b.md" ])],
           @"documents still open: %@", paths);
    Expect([payloads isEqualToArray:(@[ download, friendLink ])], @"only links that pass reach Friends: %@", payloads);
}

static void TestInfoPlist(NSString* path) {
    NSDictionary* plist = [NSDictionary dictionaryWithContentsOfFile:path];
    BOOL found = NO;
    for (NSDictionary* type in plist[@"CFBundleURLTypes"])
        for (NSString* scheme in type[@"CFBundleURLSchemes"]) found = found || [scheme isEqualToString:@"shenzhenpdf"];
    Expect(found, @"%@ registers the shenzhenpdf: scheme", path);
}

@interface LinkTarget : NSObject
@property NSMutableArray<NSNumber*>* days;
- (void)copyLink:(NSMenuItem*)sender;
@end
@implementation LinkTarget
- (void)copyLink:(NSMenuItem*)sender {
    if (!self.days) self.days = [NSMutableArray array];
    [self.days addObject:@(SPDFMacFriendsExpiryDays(sender))];
}
@end

static void TestMenus(void) {
    LinkTarget* target = [LinkTarget new];
    NSMenu* expiry = SPDFMacFriendsExpiryMenu(target, @selector(copyLink:), @"/tmp/a.pdf");
    NSArray* titles = [expiry.itemArray valueForKey:@"title"];
    Expect([titles isEqualToArray:(@[ @"For 7 Days", @"For 1 Day", @"For 30 Days" ])], @"expiry choice: %@", titles);
    for (NSMenuItem* item in expiry.itemArray) {
        Expect([item.representedObject isEqual:@"/tmp/a.pdf"] && [item.identifier hasPrefix:@"szfriends."],
               @"each choice carries the document and is hidden from the assistant");
        [NSApplication.sharedApplication sendAction:item.action to:item.target from:item];
    }
    Expect([target.days isEqualToArray:(@[ @7, @1, @30 ])], @"days: %@", target.days);
    Expect(SPDFMacFriendsExpiryDays([[NSMenuItem alloc] initWithTitle:@"x" action:nil keyEquivalent:@""]) == 0,
           @"any other item stands for no expiry");

    NSMenu* file = [[NSMenu alloc] initWithTitle:@"File"];
    [file addItemWithTitle:@"Show in Folder" action:NSSelectorFromString(@"showInFolder:") keyEquivalent:@""];
    [file addItemWithTitle:@"Copy Path" action:NSSelectorFromString(@"copyCurrentDocumentPath:") keyEquivalent:@""];
    [file addItemWithTitle:@"Save As..." action:NSSelectorFromString(@"saveDocumentAs:") keyEquivalent:@""];
    NSMenuItem* share = SPDFMacFriendsInstallShareItem(file, target, @selector(copyLink:));
    Expect(share && [file indexOfItem:share] == 2 && [share.title isEqualToString:@"Share"], @"Share after Copy Path");
    NSMenuItem* copy = share.submenu.itemArray.firstObject;
    Expect([copy.title isEqualToString:@"Copy Download Link"] && copy.submenu.numberOfItems == 3,
           @"File ▸ Share ▸ Copy Download Link ▸ the expiry choice");
    Expect([share.identifier hasPrefix:@"szfriends."] && [copy.identifier hasPrefix:@"szfriends."],
           @"hidden from the assistant");
    Expect(SPDFMacFriendsInstallShareItem(file, target, @selector(copyLink:)) == nil && file.numberOfItems == 4,
           @"never a second Share");
    SPDFMacFriendsRemoveShareItem(file);
    Expect(file.numberOfItems == 3, @"removed when Friends detaches");

    NSMenuItem* tabItem = SPDFMacFriendsCopyDownloadLinkItem(target, @selector(copyLink:), @"/tmp/b.pdf");
    Expect([tabItem.submenu.itemArray.firstObject.representedObject isEqual:@"/tmp/b.pdf"],
           @"a tab's item is for that tab's document");
}

@interface LinkBridge : NSObject <SPDFMacFriendsReaderBridge>
@property NSMutableArray* copies;
@end
@implementation LinkBridge
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { (void)button; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button { (void)button; }
- (NSArray*)friendsBridgeOpenDocuments { return @[]; }
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return nil; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { (void)paths; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)urls { (void)urls; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services { (void)services; }
- (SZFriendsAppearance*)friendsBridgeAppearance { return [SZFriendsAppearance new]; }
- (void)friendsBridgeCopyDownloadLinkForItem:(SZFriendsAttachableItem*)item days:(NSInteger)days {
    if (!self.copies) self.copies = [NSMutableArray array];
    [self.copies addObject:@[ item, @(days) ]];
}
@end

static void TestCopyLinkInstead(void) {
    LinkBridge* bridge = [LinkBridge new];
    SPDFMacFriendsHost* host = [[SPDFMacFriendsHost alloc] initWithBridge:bridge bundle:NSBundle.mainBundle
                                                                  formats:[NSSet set]];
    Expect([host.friendsCopyLinkInsteadLabel isEqualToString:@"Copy link instead"], @"the drop panel's words");
    SZFriendsAttachableItem* item = [SZFriendsAttachableItem new];
    item.title = @"Site photos.pdf";
    __block NSArray* offered = nil;
    host.presentExpiryMenu = ^NSMenuItem*(NSMenu* menu, NSView* view) {
        (void)view;
        offered = [menu.itemArray valueForKey:@"title"];
        return menu.itemArray[2];
    };
    NSView* button = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 120, 20)];
    [host friendsOfferDownloadLinkForItem:item fromView:button];
    Expect(offered.count == 3 && bridge.copies.count == 1 && bridge.copies[0][0] == item &&
               [bridge.copies[0][1] isEqual:@30],
           @"the expiry chosen copies that file's link: %@", bridge.copies);
    host.presentExpiryMenu = ^NSMenuItem*(NSMenu* menu, NSView* view) {
        (void)menu, (void)view;
        return nil;
    };
    [host friendsOfferDownloadLinkForItem:item fromView:button];
    Expect(bridge.copies.count == 1, @"a dismissed choice copies nothing");
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <Info.plist>\n", argv[0]);
            return 2;
        }
        TestPayloads();
        TestSharedDownloadPayloads();
        TestSorting();
        TestInfoPlist(@(argv[1]));
        TestMenus();
        TestCopyLinkInstead();
        printf("SPDFMacFriendsLinkTests passed\n");
        return 0;
    }
}
