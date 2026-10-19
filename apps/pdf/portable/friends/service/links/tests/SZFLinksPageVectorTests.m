// The helper's link crypto against the link pages' own JavaScript (link-page-vectors.mjs): what one side seals, the
// other opens. Needs Node.js 22 and SZFRIENDS_LINKS_PAGES_DIR (the pages' script directory); without them it says so
// and skips.

#import "SZFLinksTestSupport.h"

#import <sodium.h>

static NSDictionary *RunPages(NSString *pages, NSDictionary *input) {
    NSString *script = [[NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"link-page-vectors.mjs"];
    if (![script hasPrefix:@"/"]) {
        script = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:script];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:input options:0 error:NULL];
    NSTask *node = [NSTask new];
    node.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    node.arguments = @[ @"node", script, pages, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ];
    NSPipe *output = [NSPipe pipe];
    node.standardOutput = output;
    if (![node launchAndReturnError:NULL]) return nil;
    NSData *text = [output.fileHandleForReading readDataToEndOfFile];
    [node waitUntilExit];
    if (node.terminationStatus != 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:text options:0 error:NULL];
}

void SZFLRunPageVectorTests(void) {
    NSString *pages = NSProcessInfo.processInfo.environment[@"SZFRIENDS_LINKS_PAGES_DIR"];
    NSString *receiver = [pages stringByAppendingPathComponent:@"receiver.js"];
    if (pages.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:receiver]) {
        printf("SKIP page vectors: the link pages' scripts are not there (SZFRIENDS_LINKS_PAGES_DIR)\n");
        return;
    }
    NSData *linkID = SZFLRandom(16), *secret = SZFLRandom(32), *on = SZFLRandom(16), *sn = SZFLRandom(16);
    SZFriendsLinkKeys *opener = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:secret];
    SZFriendsLinkKeys *sender = [[SZFriendsLinkKeys alloc] initWithLinkID:linkID secret:secret];
    NSData *hello = [opener sealMessage:@{@"t" : @"hello", @"v" : @1, @"n" : SZFriendsLinkBase64URLEncode(on)}
                                   from:SZFriendsLinkSideOpener];
    NSData *challenge = [sender sealMessage:@{@"t" : @"challenge", @"o" : SZFriendsLinkBase64URLEncode(on),
                                              @"n" : SZFriendsLinkBase64URLEncode(sn)}
                                       from:SZFriendsLinkSideSender];
    [opener setOpenerNonce:on senderNonce:sn];
    [sender setOpenerNonce:on senderNonce:sn];
    NSData *answer = [sender sealMessage:@{@"t" : @"answer", @"a" : @1, @"sdp" : @"v=0"} from:SZFriendsLinkSideSender];
    NSData *content = [sender contentKeyForAttempt:1];
    SZFriendsLinkMetadata *metadata = [SZFriendsLinkMetadata new];
    metadata.name = @"Site photos.pdf";
    metadata.size = 6000000000ULL;
    metadata.mediaType = @"application/pdf";
    metadata.sha256 = SZFLRandom(32);
    metadata.senderName = @"Mei";
    NSData *finalPlain = SZFLRandom(1234);
    SZFriendsDownloadLinkPayload *download = [SZFriendsDownloadLinkPayload new];
    download.linkID = linkID;
    download.secret = secret;
    SZFriendsFriendLinkPayload *friend = [SZFriendsFriendLinkPayload new];
    friend.identityKey = SZFLRandom(32);
    friend.inviteToken = SZFLRandom(16);
    friend.friendsID = @"brave-otter";
    friend.name = @"Mei Wong";
    NSDictionary *input = @{
        @"link_id" : SZFriendsLinkBase64URLEncode(linkID), @"secret" : SZFriendsLinkBase64URLEncode(secret),
        @"opener_nonce" : SZFriendsLinkBase64URLEncode(on), @"sender_nonce" : SZFriendsLinkBase64URLEncode(sn),
        @"hello" : SZFriendsLinkBase64URLEncode(hello), @"challenge" : SZFriendsLinkBase64URLEncode(challenge),
        @"answer" : SZFriendsLinkBase64URLEncode(answer),
        @"meta" : SZFriendsLinkBase64URLEncode(SZFriendsLinkSealRecord(content, SZFriendsLinkRecordMetadata, 0,
                                                                       [metadata recordPlaintext])),
        @"final" : SZFriendsLinkBase64URLEncode(SZFriendsLinkSealRecord(content, SZFriendsLinkRecordFinal, 7,
                                                                        finalPlain)),
        @"final_plain" : SZFriendsLinkBase64URLEncode(finalPlain),
        @"download_fragment" : [[download payloadString] substringFromIndex:2],
        @"friend_fragment" : [[friend payloadString] substringFromIndex:2],
    };
    NSDictionary *out = RunPages(pages, input);
    if (out == nil) {
        printf("SKIP page vectors: node could not run the pages' scripts (Node.js 22 needed)\n");
        return;
    }
    SZFL_CHECK([out[@"hello"][@"n"] isEqual:SZFriendsLinkBase64URLEncode(on)], @"the page opens our hello: %@", out);
    SZFL_CHECK([out[@"challenge"][@"t"] isEqual:@"challenge"], @"and our challenge");
    SZFL_CHECK([out[@"answer"][@"sdp"] isEqual:@"v=0"], @"and our answer under the session key");
    SZFL_CHECK([sender verifyProof:SZFriendsLinkBase64URLDecode(out[@"proof"])], @"the page's proof verifies here");
    NSDictionary *offer = [sender openPayload:SZFriendsLinkBase64URLDecode(out[@"offer"]) from:SZFriendsLinkSideOpener];
    SZFL_CHECK([offer[@"t"] isEqual:@"offer"] && [offer[@"a"] isEqual:@1], @"the page's offer opens here: %@", offer);
    NSDictionary *meta = out[@"meta"];
    SZFL_CHECK([meta[@"name"] isEqual:@"Site photos.pdf"] && [meta[@"size"] longLongValue] == 6000000000LL &&
                   [meta[@"sender"] isEqual:@"Mei"] &&
                   [meta[@"sha256"] isEqual:SZFriendsLinkBase64URLEncode(metadata.sha256)],
               @"the page reads our metadata: %@", meta);
    SZFL_CHECK([out[@"final"][@"type"] intValue] == SZFriendsLinkRecordFinal &&
                   [out[@"final"][@"plain"] isEqual:SZFriendsLinkBase64URLEncode(finalPlain)],
               @"the page opens our final chunk");
    NSMutableData *digest = [NSMutableData dataWithLength:32];
    crypto_hash_sha256(digest.mutableBytes, finalPlain.bytes, finalPlain.length);
    SZFL_CHECK([out[@"sha256"] isEqual:SZFriendsLinkBase64URLEncode(digest)], @"the page hashes as the helper does");
    NSData *control = SZFriendsLinkOpenRecord(content, @[ @(SZFriendsLinkRecordControl) ], 0,
                                              SZFriendsLinkBase64URLDecode(out[@"control"]), NULL);
    NSDictionary *start = control ? [NSJSONSerialization JSONObjectWithData:control options:0 error:NULL] : nil;
    SZFL_CHECK([start[@"t"] isEqual:@"start"] && [start[@"upto"] isEqual:@64], @"the page's control opens here");
    SZFL_CHECK([out[@"download"][@"link_id"] isEqual:SZFriendsLinkBase64URLEncode(linkID)] &&
                   [out[@"download"][@"secret"] isEqual:SZFriendsLinkBase64URLEncode(secret)],
               @"the page reads our download link");
    SZFL_CHECK([out[@"friend"][@"friends_id"] isEqual:@"brave-otter"] && [out[@"friend"][@"name"] isEqual:@"Mei Wong"],
               @"the page reads our friend link: %@", out[@"friend"]);
}
