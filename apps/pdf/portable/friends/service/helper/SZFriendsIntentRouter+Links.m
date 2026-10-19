// Intents about links (PROTOCOL.md § Links): open_link's card, add_from_link, receive_link, make_download_link,
// reset_friend_link and revoke_link. The links service does the work (SZFriendsLinks.h); this checks fields and words
// the replies for the app that asked.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/helper/SZFriendsHelperLinks.h"
#import "service/helper/nearby/SZFriendsNearbyService.h"
#import "service/host/SZFriendsHostInternal.h"
#import "service/links/SZFriendsLinkWire.h"
#import "service/presentation/SZFriendsMentions.h"
#import "service/store/SZFriendsStoreLinks.h"

// Implemented in SZFriendsIntentRouter+Content.m and +Mentions.m.
@interface SZFriendsIntentRouter (LinksShared)
- (BOOL)parseRevision:(id)object into:(SZFriendsRevision *_Nullable *_Nonnull)revision;
- (void)intent_add_from_mention:(NSDictionary *)intent
                     connection:(SZFriendsIPCConnection *)connection
                          reply:(SZFriendsIntentReply)reply;
@end

@implementation SZFriendsIntentRouter (Links)

- (nullable id)linkPayloadIn:(NSDictionary *)intent
                       class:(Class)kind
                       reply:(SZFriendsIntentReply)reply
                  connection:(SZFriendsIPCConnection *)connection {
    NSString *text = [self requiredString:@"payload" in:intent maxLength:SZFriendsLinkPayloadMax reply:reply
                               connection:connection];
    if (text == nil) return nil;
    id payload = SZFriendsParseLinkPayload(text);
    if (payload == nil || (kind != Nil && ![payload isKindOfClass:kind])) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"payload"} connection:connection];
        return nil;
    }
    return payload;
}

- (SZFriendsSnapshotBuilder *)builderForConnection:(SZFriendsIPCConnection *)connection {
    return [self.publisher stateForConnection:connection].builder;
}

- (void)intent_open_link:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                   reply:(SZFriendsIntentReply)reply {
    id payload = [self linkPayloadIn:intent class:Nil reply:reply connection:connection];
    if (payload == nil) return;
    SZFriendsSnapshotBuilder *builder = [self builderForConnection:connection];
    if ([payload isKindOfClass:[SZFriendsDownloadLinkPayload class]]) {
        [self succeed:reply result:@{@"card" : [builder downloadLinkCardWithPayload:intent[@"payload"]]}];
        return;
    }
    SZFriendsFriendLinkPayload *link = payload;
    if ([link.identityKey isEqualToData:self.services.identity.publicKey]) {
        [self fail:reply code:@"id_is_yours" details:nil connection:connection];
        return;
    }
    SZFriendsPersonRecord *known = [self.services.store personWithIdentityKey:link.identityKey];
    BOOL friend = known != nil && known.relation == SZFriendsRelationFriend;
    [self succeed:reply result:@{@"card" : [builder friendLinkCardWithName:link.name friendsID:link.friendsID
                                                                    payload:intent[@"payload"]
                                                              alreadyFriend:friend]}];
}

// Add by ID for exactly the key in the link (add_from_mention's rules), presenting the link's invite, which the
// inviter's Mac checks and then accepts at once.
- (void)intent_add_from_link:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    SZFriendsFriendLinkPayload *link = [self linkPayloadIn:intent class:[SZFriendsFriendLinkPayload class] reply:reply
                                                connection:connection];
    if (link == nil) return;
    NSString *name = SZFriendsMentionName(link.name, link.friendsID);
    NSDictionary *asMention = @{@"type" : @"add_from_mention", @"id" : intent[@"id"] ?: @"",
                                @"friends_id" : link.friendsID, @"name" : name,
                                @"identity_key" : SZFriendsMentionKeyString(link.identityKey)};
    SZFriendsStore *store = self.services.store;
    SZFriendsSnapshotBuilder *builder = [self builderForConnection:connection];
    BOOL online = self.services.nearby.reachesFriendsOnline; // the request also goes through the host
    [self intent_add_from_mention:asMention connection:connection
                            reply:^(NSDictionary *result, NSString *code, NSString *message, NSDictionary *details) {
                                NSString *conversationID = result[@"conversation_id"];
                                if (code != nil || ![conversationID isKindOfClass:[NSString class]]) {
                                    reply(result, code, message, details);
                                    return;
                                }
                                [store setInviteToken:link.inviteToken forIDRequestConversation:conversationID
                                                error:NULL];
                                reply(@{@"conversation_id" : conversationID,
                                        @"message" : [builder linkRequestSentMessageForName:name online:online]},
                                      nil, nil, nil);
                            }];
}

- (void)intent_receive_link:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    SZFriendsDownloadLinkPayload *link = [self linkPayloadIn:intent class:[SZFriendsDownloadLinkPayload class]
                                                       reply:reply
                                                  connection:connection];
    if (link == nil) return;
    SZFriendsLinkService *links = [self.services linkService];
    SZFriendsSnapshotBuilder *builder = [self builderForConnection:connection];
    __weak SZFriendsIntentRouter *weakSelf = self;
    [links receiveLink:link started:^(NSString *conversationID, SZFriendsLinkMetadata *metadata,
                                      SZFriendsLinkOutcome outcome) {
        SZFriendsIntentRouter *router = weakSelf;
        if (conversationID != nil && metadata != nil) {
            [router succeed:reply result:@{@"conversation_id" : conversationID,
                                           @"message" : [builder linkReceivingMessageForFile:metadata.name
                                                                                      sender:metadata.senderName]}];
            return;
        }
        NSString *code = outcome == SZFriendsLinkOutcomeEnded     ? @"not_found"
                         : outcome == SZFriendsLinkOutcomeChanged ? @"link_changed"
                         : outcome == SZFriendsLinkOutcomeFailed  ? @"link_failed"
                                                                  : @"link_offline";
        [router fail:reply code:code details:@{@"field" : @"payload"} connection:connection];
    }];
    if (links == nil) [self fail:reply code:@"link_offline" details:nil connection:connection];
}

- (void)intent_make_download_link:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                            reply:(SZFriendsIntentReply)reply {
    NSDictionary *file = [intent[@"file"] isKindOfClass:[NSDictionary class]] ? intent[@"file"] : nil;
    NSString *path = file[@"path"];
    id name = file[@"display_name"], days = intent[@"expires_days"];
    SZFriendsRevision *revision = nil;
    if (!SZFriendsJSONIsString(path) || ![path hasPrefix:@"/"] || (name && name != [NSNull null] &&
                                                                   !SZFriendsJSONIsString(name)) ||
        ![self parseRevision:file[@"revision"] into:&revision]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"file"} connection:connection];
        return;
    }
    if (!SZFriendsJSONIsInteger(days) || ![@[ @1, @7, @30 ] containsObject:days]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"expires_days"} connection:connection];
        return;
    }
    SZFriendsLinkService *links = [self.services linkService];
    if (links == nil || links.linkOrigin == nil || links.linkOrigin() == nil) {
        [self fail:reply code:@"not_allowed" details:nil connection:connection];
        return;
    }
    SZFriendsSnapshotBuilder *builder = [self builderForConnection:connection];
    __weak SZFriendsIntentRouter *weakSelf = self;
    [links makeDownloadLinkForPath:path
                       displayName:SZFriendsJSONIsString(name) ? name : nil
                    revisionSHA256:revision.sha256
                      revisionSize:revision ? @(revision.size) : nil
                       expiresDays:[days integerValue]
                        completion:^(SZFriendsDownloadLinkRecord *link, NSString *url, NSError *error) {
                            SZFriendsIntentRouter *router = weakSelf;
                            if (link == nil || url == nil) {
                                BOOL limit = [error.domain isEqualToString:SZFriendsStoreErrorDomain] &&
                                             error.code == SZFriendsStoreErrorConstraint;
                                NSString *code = limit ? @"too_many_links" : SZFriendsStoreProtocolErrorCode(error);
                                [router fail:reply code:code details:@{@"path" : path} connection:connection];
                                return;
                            }
                            [router succeed:reply result:@{
                                @"url" : url, @"link_id" : SZFriendsHostBase64URLEncode(link.linkID),
                                @"message" : [builder downloadLinkMadeMessageUntil:link.expiresAt]
                            }];
                        }];
}

- (void)intent_reset_friend_link:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                           reply:(SZFriendsIntentReply)reply {
    (void)intent;
    NSError *error = nil;
    SZFriendsLinkService *links = [self.services linkService];
    if (links == nil || ![links resetFriendLinkWithError:&error]) {
        [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

- (void)intent_revoke_link:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                     reply:(SZFriendsIntentReply)reply {
    NSData *linkID = SZFriendsHostBase64URLDecode(intent[@"link_id"], 16);
    if (linkID == nil) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"link_id"} connection:connection];
        return;
    }
    NSError *error = nil;
    if (![[self.services linkService] revokeLinkID:linkID error:&error]) {
        [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

@end
