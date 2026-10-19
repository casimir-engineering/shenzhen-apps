// friends-identity-check: CPace against draft-irtf-cfrg-cpace-13, Appendix B.3 (ristretto255 with SHA-512), step by
// step: generator string, generator, both shares, K, ISK with the initiator-responder transcript, and the two invalid
// inputs scalar_mult_vfy must refuse. Then a run between two objects: same code, same keys; any other code, CI or sid,
// different ones.

#import "SZFriendsIdentityTestSupport.h"

#import "service/identity/SZFriendsCPace.h"

static NSData *Text(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }

// Appendix B.3, transcribed with its line breaks removed.
static NSString *const kCI = @"6f630b425f726573706f6e6465720b415f696e69746961746f72";
static NSString *const kSID = @"7e4b4791d6a8ef019b936c79fb7f2c57";
static NSString *const kGeneratorString =
    @"11435061636552697374726574746f3235350850617373776f726464"
    @"00000000000000000000000000000000000000000000000000000000"
    @"00000000000000000000000000000000000000000000000000000000"
    @"00000000000000000000000000000000000000000000000000000000"
    @"000000000000000000000000000000001a6f630b425f726573706f6e"
    @"6465720b415f696e69746961746f72107e4b4791d6a8ef019b936c79"
    @"fb7f2c57";
static NSString *const kGenerator = @"a6fc82c3b8968fbb2e06fee81ca858586dea50d248f0c7ca6a18b0902a30b36b";
static NSString *const kYa = @"da3d23700a9e5699258aef94dc060dfda5ebb61f02a5ea77fad53f4ff0976d08";
static NSString *const kShareA = @"d40fb265a7abeaee7939d91a585fe59f7053f982c296ec413c624c669308f87a";
static NSString *const kYb = @"d2316b454718c35362d83d69df6320f38578ed5984651435e2949762d900b80d";
static NSString *const kShareB = @"08bcf6e9777a9c313a3db6daa510f2d398403319c2341bd506a92e672eb7e307";
static NSString *const kK = @"e22b1ef7788f661478f3cddd4c600774fc0f41e6b711569190ff88fa0e607e09";
static NSString *const kISK =
    @"4c5469a16b2364c4b944ebc1a79e51d1674ad47db26e8718154f59faebfaa52d"
    @"8346f30aa58377117eb20d527f2cbc5c76381f7fd372e89df8239f87f2e02ed1";
static NSString *const kScalar = @"7cd0e075fa7955ba52c02759a6c90dbbfc10e6d40aea8d283e407d88cf538a05";
static NSString *const kValidX = @"2c3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c";
static NSString *const kValidProduct = @"7c13645fe790a468f62c39beb7388e541d8405d1ade69d1778c5fe3e7f6b600e";
static NSString *const kInvalidY = @"2b3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c";

static void TestHelpers(void) {
    // Appendix A.1's own examples.
    SZFExpect([SZFriendsCPacePrependLength(Text(@"1234")) isEqualToData:SZFHex(@"0431323334")], @"prepend_len");
    NSData *long130 = [NSMutableData dataWithLength:130];
    SZFExpect([[SZFriendsCPacePrependLength(long130) subdataWithRange:NSMakeRange(0, 2)]
                  isEqualToData:SZFHex(@"8201")], @"LEB128 of 130");
    NSData *cat = SZFriendsCPaceLVCat(@[ Text(@"1234"), Text(@"5"), [NSData data], Text(@"678") ]);
    SZFExpect([cat isEqualToData:SZFHex(@"043132333401350003363738")], @"lv_cat");
}

static void TestVectors(void) {
    NSData *prs = Text(@"Password"), *ci = SZFHex(kCI), *sid = SZFHex(kSID);
    SZFExpect([Text(@"oc\x0b" "B_responder\x0b" "A_initiator") isEqualToData:ci], @"CI as the draft spells it");
    SZFExpect([SZFriendsCPaceGeneratorString(prs, ci, sid) isEqualToData:SZFHex(kGeneratorString)],
              @"generator_string");
    NSData *generator = SZFriendsCPaceGenerator(prs, ci, sid);
    SZFExpect([generator isEqualToData:SZFHex(kGenerator)], @"g: %@", generator);

    SZFriendsCPace *a = [[SZFriendsCPace alloc] initWithPassword:prs channelIdentifier:ci sessionID:sid
                                                          scalar:SZFHex(kYa)];
    SZFriendsCPace *b = [[SZFriendsCPace alloc] initWithPassword:prs channelIdentifier:ci sessionID:sid
                                                          scalar:SZFHex(kYb)];
    SZFExpect([a.share isEqualToData:SZFHex(kShareA)], @"Ya: %@", a.share);
    SZFExpect([b.share isEqualToData:SZFHex(kShareB)], @"Yb: %@", b.share);
    SZFExpect([SZFriendsCPaceScalarMultVfy(SZFHex(kYa), b.share) isEqualToData:SZFHex(kK)], @"K from A");
    SZFExpect([SZFriendsCPaceScalarMultVfy(SZFHex(kYb), a.share) isEqualToData:SZFHex(kK)], @"K from B");

    NSData *iskA = [a iskAsInitiatorWithAD:Text(@"ADa") peerShare:b.share peerAD:Text(@"ADb")];
    NSData *iskB = [b iskAsResponderWithAD:Text(@"ADb") peerShare:a.share peerAD:Text(@"ADa")];
    SZFExpect([iskA isEqualToData:SZFHex(kISK)], @"ISK_IR from A: %@", iskA);
    SZFExpect([iskB isEqualToData:SZFHex(kISK)], @"ISK_IR from B: %@", iskB);

    // B.3.10 and B.3.11.
    SZFExpect([SZFriendsCPaceScalarMultVfy(SZFHex(kScalar), SZFHex(kValidX)) isEqualToData:SZFHex(kValidProduct)],
              @"scalar_mult_vfy, valid input");
    SZFExpect(SZFriendsCPaceScalarMultVfy(SZFHex(kScalar), SZFHex(kInvalidY)) == nil, @"Y_i1 refused");
    SZFExpect(SZFriendsCPaceScalarMultVfy(SZFHex(kScalar), [NSMutableData dataWithLength:32]) == nil,
              @"the identity refused");
    SZFExpect([a iskAsInitiatorWithAD:Text(@"ADa") peerShare:[NSMutableData dataWithLength:32]
                               peerAD:Text(@"ADb")] == nil, @"an identity share aborts the run");
}

// Two fresh runs agree only on the same password, CI and sid.
static void TestRuns(void) {
    NSData *ci = Text(@"channel"), *sid = [NSMutableData dataWithLength:64];
    NSData *other = SZFHex(@"01");
    NSArray<NSArray<NSData *> *> *cases = @[
        @[ Text(@"48312207"), ci, sid, Text(@"48312207"), ci, sid ],
        @[ Text(@"48312207"), ci, sid, Text(@"48312208"), ci, sid ],
        @[ Text(@"48312207"), ci, sid, Text(@"48312207"), other, sid ],
        @[ Text(@"48312207"), ci, sid, Text(@"48312207"), ci, [NSMutableData dataWithLength:63] ],
    ];
    for (NSUInteger i = 0; i < cases.count; i++) {
        NSArray<NSData *> *c = cases[i];
        SZFriendsCPace *a = [[SZFriendsCPace alloc] initWithPassword:c[0] channelIdentifier:c[1] sessionID:c[2]
                                                              scalar:nil];
        SZFriendsCPace *b = [[SZFriendsCPace alloc] initWithPassword:c[3] channelIdentifier:c[4] sessionID:c[5]
                                                              scalar:nil];
        NSData *iskA = [a iskAsInitiatorWithAD:Text(@"new") peerShare:b.share peerAD:Text(@"old")];
        NSData *iskB = [b iskAsResponderWithAD:Text(@"old") peerShare:a.share peerAD:Text(@"new")];
        SZFExpect(iskA.length == 64 && iskB.length == 64, @"case %lu: keys", (unsigned long)i);
        SZFExpect([iskA isEqualToData:iskB] == (i == 0), @"case %lu: agreement only for the same inputs",
                  (unsigned long)i);
    }
    // Different associated data also changes the key, so what each side binds there cannot be swapped.
    SZFriendsCPace *a = [[SZFriendsCPace alloc] initWithPassword:Text(@"1") channelIdentifier:ci sessionID:sid
                                                          scalar:nil];
    SZFriendsCPace *b = [[SZFriendsCPace alloc] initWithPassword:Text(@"1") channelIdentifier:ci sessionID:sid
                                                          scalar:nil];
    SZFExpect(![[a iskAsInitiatorWithAD:Text(@"new") peerShare:b.share peerAD:Text(@"old")]
                 isEqualToData:[b iskAsResponderWithAD:Text(@"mallory") peerShare:a.share peerAD:Text(@"new")]],
              @"AD bound");
}

int main(void) {
    @autoreleasepool {
        TestHelpers();
        TestVectors();
        TestRuns();
        return SZFFinish("SZFriendsCPaceTests");
    }
}
