// The session suite's groups, run in order by SZFriendsSessionTests.m.

#import <Foundation/Foundation.h>

void SZFRunNoiseVectorTests(NSString *vectorDirectory);
void SZFRunNoiseUnitTests(void);
void SZFRunFrameCodecTests(void);
void SZFRunChannelTests(void);
void SZFRunChannelPolicyTests(void);
void SZFRunChannelFaultTests(void);
void SZFRunChannelLifetimeTests(void);
void SZFRunScriptedPeerTests(void);
void SZFRunCodeTests(void);
void SZFRunChunkFlowTests(void);
void SZFRunTransferResumeTests(void);
void SZFRunChannelRefusalTests(void);
void SZFRunChannelIdentityTests(void);
void SZFRunSignatureDomainTests(NSString *vectorDirectory);
void SZFRunThumbnailFrameTests(void);
void SZFRunChainFrameTests(void);
void SZFRunJoinFrameTests(void);
void SZFRunSyncFrameTests(void);
