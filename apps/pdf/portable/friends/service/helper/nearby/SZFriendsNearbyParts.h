// Categories of the nearby service declared apart from SZFriendsNearbyInternal.h, which imports this at its end:
// import that one.

NS_ASSUME_NONNULL_BEGIN

// Who this computer is to Nearby, and what it advertises (SZFriendsNearbyService+Advertising.m).
@interface SZFriendsNearbyService (Advertising)
- (void)refreshAdvertisement;
- (void)rebuildTagMatcher;
- (NSData *)localIdentityKey;
// The name, Friends ID and picture friends see, as PROFILE fields (also the public entry's profile).
- (NSDictionary<NSNumber *, NSData *> *)profileFields;
- (int64_t)currentWindow;
@end

@interface SZFriendsNearbyService (Inbound)
- (void)link:(SZFriendsPeerLink *)link receivedFrame:(SZFriendsFrame *)frame;
// A PART or CHUNK sent or received on `link`: its file bytes count for its transfer on the link's route (+Facts).
- (void)link:(SZFriendsPeerLink *)link meterFrame:(SZFriendsFrame *)frame;
// Our request to this conversation arrived (an answer, or a callback presenting its token): Delivered.
- (void)acknowledgeRequestEntriesOfConversation:(NSString *)conversationID;
// An outbox entry with no history item (answers, presence secrets), as the router queues them.
- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
            payload:(nullable NSDictionary *)payload;
@end

// Messages, offers, presence secrets and profiles from a friend (SZFriendsNearbyService+InboundContent.m).
@interface SZFriendsNearbyService (InboundContent)
- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedMessage:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedOffer:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link
                person:(SZFriendsPersonRecord *)person
    receivedOfferReply:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person
    receivedPresenceSecret:(SZFriendsFrame *)frame;
- (void)link:(SZFriendsPeerLink *)link receivedProfile:(SZFriendsFrame *)frame;
- (void)applyProfile:(NSDictionary<NSNumber *, NSData *> *)fields toPerson:(SZFriendsPersonRecord *)person;
// Name, Friends ID and picture from PROFILE fields (or a public profile), cleaned and validated; not saved.
- (void)updatePerson:(SZFriendsPersonRecord *)person withProfile:(NSDictionary<NSNumber *, NSData *> *)fields;
@end

NS_ASSUME_NONNULL_END
