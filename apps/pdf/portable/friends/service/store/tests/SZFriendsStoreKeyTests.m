// Key rules: a person's identity key never changes through a save, and a static key changes only through the
// reviewed path, which takes a certificate from the same identity key (ADR 0001 § Keys; security review, "key
// change handling").

#import "service/identity/SZFriendsIdentity.h"

#import "SZFriendsStoreTestSupport.h"

// An identity with a chosen signing seed and static key, so two can share an identity key and differ in static key.
static SZFriendsIdentity *Identity(uint8_t seed, uint8_t staticKey) {
    return [SZFriendsIdentity identityWithSigningSeed:SZFTBytes(seed, 32) staticPrivateKey:SZFTBytes(staticKey, 32)];
}

static SZFriendsPersonRecord *SavedPerson(SZFriendsStore *store, NSString *conversationID,
                                          SZFriendsIdentity *identity) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = identity.publicKey;
    person.staticKey = identity.staticPublicKey;
    person.relation = SZFriendsRelationFriend;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSince1970:1000];
    NSError *error = nil;
    SZFTExpect([store savePerson:person error:&error], @"save %@: %@", conversationID, error);
    return person;
}

// The review's failure: a second key saved onto a known conversation silently took it over (messages, history and
// later IK dials went to the new key). It must be refused and change nothing.
static void TestSavesNeverRebindAConversation(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"rebind"));
    SZFriendsPersonRecord *mei = SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    mei.verified = YES;
    mei.autoAccept = YES;
    SZFTExpect([store savePerson:mei error:NULL], @"trust earned by the first key");
    NSError *error = nil;
    SZFriendsPersonRecord *other = [mei copy];
    other.identityKey = SZFTBytes(42, 32);
    other.staticKey = SZFTBytes(43, 32);
    SZFTExpect(![store savePerson:other error:&error] && error.code == SZFriendsStoreErrorKeyChangeRefused,
               @"another identity key is refused: %@", error);
    SZFriendsPersonRecord *read = [store personWithConversationID:@"mei"];
    SZFTExpect([read.identityKey isEqualToData:SZFTBytes(1, 32)] && [read.staticKey isEqualToData:SZFTBytes(2, 32)] &&
                   read.verified && read.autoAccept, @"and nothing changed");
    SZFTExpect([store personWithIdentityKey:SZFTBytes(42, 32)] == nil, @"the new key belongs to nobody");
    other = [mei copy];
    other.identityKey = nil;
    SZFTExpect(![store savePerson:other error:&error] && error.code == SZFriendsStoreErrorKeyChangeRefused,
               @"clearing the identity key is refused");
    other = [mei copy];
    other.staticKey = SZFTBytes(44, 32);
    SZFTExpect(![store savePerson:other error:&error] && error.code == SZFriendsStoreErrorKeyChangeRefused,
               @"a static key change outside review is refused");
    other.staticKey = nil;
    SZFTExpect(![store savePerson:other error:&error] && error.code == SZFriendsStoreErrorKeyChangeRefused,
               @"so is clearing it");
    // An Add by ID row learns its keys once, then keeps them.
    SZFriendsPersonRecord *asked = [[SZFriendsPersonRecord alloc] init];
    asked.conversationID = @"asked";
    asked.friendsID = @"orchid-summit";
    asked.relation = SZFriendsRelationOutgoingRequest;
    SZFTExpect([store savePerson:asked error:NULL], @"no key yet");
    asked.identityKey = SZFTBytes(50, 32);
    SZFTExpect([store savePerson:asked error:&error], @"a first identity key is set: %@", error);
    asked.staticKey = SZFTBytes(51, 32);
    SZFTExpect([store savePerson:asked error:&error], @"a first static key is set: %@", error);
    asked.identityKey = SZFTBytes(52, 32);
    SZFTExpect(![store savePerson:asked error:&error] && error.code == SZFriendsStoreErrorKeyChangeRefused,
               @"then never replaced");
    SZFTExpect([SZFriendsStoreProtocolErrorCode(error) isEqualToString:@"internal"], @"an intent says internal");
}

static void TestReviewedStaticKeyChange(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"keychange"));
    SZFriendsIdentity *mei = Identity(1, 11);
    SZFriendsIdentity *meiNewStatic = Identity(1, 12); // the same identity key certifying another static key
    SZFriendsIdentity *mallory = Identity(9, 12);       // another identity key, the same static key
    SZFTExpect([mei.publicKey isEqualToData:meiNewStatic.publicKey] &&
                   ![mei.staticPublicKey isEqualToData:meiNewStatic.staticPublicKey], @"fixture identities");
    SZFriendsPersonRecord *person = SavedPerson(store, @"mei", mei);
    person.verified = YES;
    person.autoAccept = YES;
    [store savePerson:person error:NULL];
    NSError *error = nil;
    SZFTExpect(![store notePresentedStaticKey:mallory.staticPublicKey certificate:mallory.staticCertificate
                              forConversation:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorKeyChangeRefused, @"another identity's key is a stranger: %@",
               error);
    SZFTExpect(![store notePresentedStaticKey:meiNewStatic.staticPublicKey certificate:mei.staticCertificate
                              forConversation:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorKeyChangeRefused, @"a certificate for another static key");
    SZFTExpect(![store notePresentedStaticKey:SZFTBytes(1, 31) certificate:mei.staticCertificate
                              forConversation:@"mei" error:&error] && error.code == SZFriendsStoreErrorInvalid,
               @"key length");
    SZFTExpect(![store notePresentedStaticKey:mei.staticPublicKey certificate:mei.staticCertificate
                              forConversation:@"nobody" error:&error] && error.code == SZFriendsStoreErrorNotFound,
               @"unknown conversation");
    SZFriendsPersonRecord *read = [store personWithConversationID:@"mei"];
    SZFTExpect(!read.pendingStaticKey && !read.keyChangePending && read.autoAccept, @"refusals store nothing");
    SZFTExpect([store notePresentedStaticKey:mei.staticPublicKey certificate:mei.staticCertificate
                             forConversation:@"mei" error:&error] &&
                   ![store personWithConversationID:@"mei"].keyChangePending, @"the stored key again is a no-op");
    SZFTExpect([store notePresentedStaticKey:meiNewStatic.staticPublicKey certificate:meiNewStatic.staticCertificate
                             forConversation:@"mei" error:&error], @"a certified new key is noted: %@", error);
    read = [store personWithConversationID:@"mei"];
    SZFTExpect([read.pendingStaticKey isEqualToData:meiNewStatic.staticPublicKey] && read.keyChangePending &&
                   !read.autoAccept && [read.staticKey isEqualToData:mei.staticPublicKey],
               @"pending review; automatic acceptance off; IK still dials the old key");
    read.name = @"Mei Lin";
    SZFTExpect([store savePerson:read error:NULL] && [store personWithConversationID:@"mei"].pendingStaticKey,
               @"a save while the change is pending keeps the noted key");
    SZFTExpect([store acceptPendingStaticKeyForConversation:@"mei" error:&error], @"accept: %@", error);
    read = [store personWithConversationID:@"mei"];
    SZFTExpect([read.staticKey isEqualToData:meiNewStatic.staticPublicKey] && !read.pendingStaticKey &&
                   !read.keyChangePending && !read.verified && !read.autoAccept &&
                   [read.identityKey isEqualToData:mei.publicKey],
               @"the new key is dialed; nothing the old one earned carries over");
    SZFTExpect(![store acceptPendingStaticKeyForConversation:@"mei" error:&error] &&
                   error.code == SZFriendsStoreErrorStale, @"nothing pending any more");
    // Dismissing a change (a save with keyChangePending off) forgets the noted key, so a later accept cannot apply it.
    [store notePresentedStaticKey:mei.staticPublicKey certificate:mei.staticCertificate forConversation:@"mei"
                            error:NULL];
    read = [store personWithConversationID:@"mei"];
    read.keyChangePending = NO;
    [store savePerson:read error:NULL];
    SZFTExpect(![store personWithConversationID:@"mei"].pendingStaticKey &&
                   ![store acceptPendingStaticKeyForConversation:@"mei" error:NULL], @"dismissed");
    SZFriendsPersonRecord *unnamed = [[SZFriendsPersonRecord alloc] init];
    unnamed.conversationID = @"unnamed";
    unnamed.relation = SZFriendsRelationOutgoingRequest;
    [store savePerson:unnamed error:NULL];
    SZFTExpect(![store notePresentedStaticKey:mei.staticPublicKey certificate:mei.staticCertificate
                              forConversation:@"unnamed" error:&error] && error.code == SZFriendsStoreErrorInvalid,
               @"a row with no identity key has no static key to change");
}

void SZFTRunKeyTests(void) {
    TestSavesNeverRebindAConversation();
    TestReviewedStaticKeyChange();
}
