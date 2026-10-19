#pragma once
// Name resolution and the connection open_page uses, as two protocols so tests replace both (no test touches the
// network). The connector is handed the numeric address the fetcher already checked and connects to exactly that
// address: the name is never resolved a second time, so a DNS answer that changes between the check and the
// connection (rebinding) cannot redirect the request into the person's network. The certificate is still checked
// against the name.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPDFMacAIWebResolution)(NSArray<NSString*>* _Nullable addresses, NSError* _Nullable error);

@protocol SPDFMacAIWebResolving <NSObject>
// Every address `host` resolves to, as numeric text. The completion runs once, on any queue.
- (void)resolveHost:(NSString*)host completion:(SPDFMacAIWebResolution)completion;
@end

@protocol SPDFMacAIWebConnecting <NSObject>
// Connects over TLS to `address` (numeric) on `port`, checking the certificate for `serverName` (nil for a numeric
// host, then the address itself), sends `request` and hands each piece of the response to `receive`, which returns
// NO to stop reading. `finished` runs once: nil when the server closed the connection or `receive` stopped, an
// error otherwise. Both run on `queue`. Returns a block that cancels; `finished` then still runs, with an error.
- (dispatch_block_t)exchangeRequest:(NSData*)request address:(NSString*)address port:(uint16_t)port
                         serverName:(nullable NSString*)serverName queue:(dispatch_queue_t)queue
                            receive:(BOOL (^)(NSData* bytes))receive
                           finished:(void (^)(NSError* _Nullable error))finished;
@end

// getaddrinfo on a background queue; numeric results only.
@interface SPDFMacAIWebSystemResolver : NSObject <SPDFMacAIWebResolving>
@end

// Network.framework TLS 1.2+ to a numeric endpoint, SNI and certificate validation for the name. It checks the
// address again itself (SPDFMacAIWebAddressRefusal) immediately before connecting, so no caller can reach a private
// address through it by mistake.
@interface SPDFMacAIWebTLSConnector : NSObject <SPDFMacAIWebConnecting>
- (instancetype)init;
// Tests only: `check` replaces the address check (nil keeps it), so a suite can watch a real connection arrive at a
// loopback listener and see the name it was told. Production code always uses -init.
- (instancetype)initWithAddressCheck:(NSString* _Nullable (^_Nullable)(NSString* address))check
    NS_DESIGNATED_INITIALIZER;
@property(nonatomic) NSTimeInterval connectTimeout; // 10 s
@end

NS_ASSUME_NONNULL_END
