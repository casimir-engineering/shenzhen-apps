#import "SPDFMacCollectionCredentials.h"
#import "SPDFMacPassword.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "SPDFMacKeychainNoninteractiveChecks.h"
static int failures;
static void Expect(NSString* label,BOOL ok) { if(!ok){fprintf(stderr,"FAIL %s\n",label.UTF8String); failures++;} }
#import "SPDFMacCollectionCredentialTestKeychain.h"
static NSString* Password(SPDFPasswordCredential* credential) {
    __block NSString* result=nil;
    [credential withUTF8Password:^(const char* bytes) { result=[NSString stringWithUTF8String:bytes]; }];
    return result;
}
int main(void) {
    @autoreleasepool {
        CheckNoninteractiveGuard(^(BOOL ok,NSString* label){Expect(label,ok);});
        MemoryKeychain* memory=[MemoryKeychain new];
        SPDFMacCollectionCredentials* store=[[SPDFMacCollectionCredentials alloc] initWithKeychain:memory];
        Expect(@"constructing credentials does no Keychain work",memory.reads+memory.adds+memory.updates==0);
        NSError* error=nil;
        NSString* hash=[@"A" stringByPaddingToLength:64 withString:@"A" startingAtIndex:0];
        NSString* second=[@"B" stringByPaddingToLength:64 withString:@"B" startingAtIndex:0];
        SPDFPasswordCredential* credential=[[SPDFPasswordCredential alloc] initWithPassword:@"秘密 café"];
        Expect(@"invalid hash rejected before Keychain",![store storeCredential:credential forHash:@"../path" error:&error] && error && memory.adds==0);
        Expect(@"short lookup rejected before Keychain",![store credentialForHash:@"abcd" error:&error] && error && memory.reads==0);
        Expect(@"missing password is a normal cache miss",![store credentialForHash:hash error:&error] && !error);
        Expect(@"successful password stored",[store storeCredential:credential forHash:hash error:&error] && !error);
        Expect(@"account is the normalized immutable hash",[memory.lastQuery[(__bridge id)kSecAttrAccount] isEqual:hash.lowercaseString]);
        Expect(@"dedicated service",[memory.lastQuery[(__bridge id)kSecAttrService] isEqual:@"com.intuition.shenzhenpdf.collection.password"]);
        Expect(@"local generic password only",[memory.lastQuery[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword] &&
            [memory.lastQuery[(__bridge id)kSecAttrSynchronizable] isEqual:@NO]);
        Expect(@"Keychain background access never prompts",[(LAContext*)memory.lastQuery[(__bridge id)kSecUseAuthenticationContext] interactionNotAllowed]);
        Expect(@"Collection add disallows authentication UI",NoninteractiveQuery(memory.lastQuery));
        BOOL wiped=YES; const unsigned char* transfer=(const unsigned char*)memory.transferredBytes.bytes;
        for(NSUInteger i=0;i<memory.transferredBytes.length;i++) if(transfer[i]) wiped=NO;
        Expect(@"temporary password transfer buffer is wiped",wiped);
        // A fresh backend object models a new process; it shares only Keychain storage,
        // not a credential dictionary, source path, Collection file or session cache.
        SPDFMacCollectionCredentials* relaunched=[[SPDFMacCollectionCredentials alloc] initWithKeychain:memory];
        Expect(@"password survives a new backend instance and Unicode roundtrips",[Password([relaunched credentialForHash:hash.lowercaseString error:&error]) isEqual:@"秘密 café"] && !error);
        Expect(@"lookup requests only one item's secret",[memory.lastQuery[(__bridge id)kSecReturnData] isEqual:@YES] &&
            [memory.lastQuery[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitOne]);
        Expect(@"Collection read disallows authentication UI",NoninteractiveQuery(memory.lastQuery));
        Expect(@"unrelated document never reuses password",![relaunched credentialForHash:second error:&error] && !error);
        credential=[[SPDFPasswordCredential alloc] initWithPassword:@"updated"];
        Expect(@"duplicate item updates without deleting protection",[store storeCredential:credential forHash:hash error:&error] && memory.updates==1);
        Expect(@"Collection update disallows authentication UI",NoninteractiveQuery(memory.lastQuery));
        Expect(@"updated credential retrieved",[Password([store credentialForHash:hash error:&error]) isEqual:@"updated"]);
        memory.failure=errSecInteractionNotAllowed;
        Expect(@"locked Keychain returns actionable error",![store credentialForHash:hash error:&error] && error.code==errSecInteractionNotAllowed);
        Expect(@"locked Keychain cannot pretend save succeeded",![store storeCredential:credential forHash:hash error:&error] && error.code==errSecInteractionNotAllowed);
        memory.failure=errSecAuthFailed;
        Expect(@"denied access remains an error",![store credentialForHash:hash error:&error] && error.code==errSecAuthFailed);
        memory.failure=0;
        unsigned char invalid[]={0xff,0xfe}; memory.items[hash.lowercaseString]=[NSData dataWithBytes:invalid length:2];
        Expect(@"corrupt password bytes rejected",![store credentialForHash:hash error:&error] && error.code==errSecDecode);
        unsigned char truncated[]={'a',0,'b'}; memory.items[hash.lowercaseString]=[NSData dataWithBytes:truncated length:3];
        Expect(@"embedded NUL cannot silently truncate a remembered password",![store credentialForHash:hash error:&error] && error.code==errSecDecode);
        credential=[[SPDFPasswordCredential alloc] initWithPassword:@""];
        Expect(@"empty PDF passwords remain valid",[store storeCredential:credential forHash:second error:&error] &&
            [Password([store credentialForHash:second error:&error]) isEqual:@""]);
        if(!failures) puts("SPDFMacCollectionCredentialsTests passed");
        return failures ? 1 : 0;
    }
}
