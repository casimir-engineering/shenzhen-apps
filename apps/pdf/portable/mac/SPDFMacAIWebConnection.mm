#import "SPDFMacAIWebConnection.h"
#import "SPDFMacAIWebAddress.h"
#import <Network/Network.h>
#import <Security/Security.h>
#include <netdb.h>

// The app's link line lives in portable/Makefile and its sources are globbed from mac/*.mm, so this object names the
// frameworks it needs itself: the reader, its probes and the test suites link them with no shared build file edited.
__asm__(".linker_option \"-framework\", \"Network\"");
__asm__(".linker_option \"-framework\", \"Security\"");

@implementation SPDFMacAIWebSystemResolver
- (void)resolveHost:(NSString*)host completion:(SPDFMacAIWebResolution)completion {
    NSString* name = [host copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct addrinfo hints;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_flags = AI_ADDRCONFIG; // no IPv6 answers on a network that cannot reach them
        struct addrinfo* list = NULL;
        NSMutableOrderedSet<NSString*>* addresses = [NSMutableOrderedSet orderedSet];
        if (getaddrinfo(name.UTF8String, NULL, &hints, &list) == 0) {
            for (struct addrinfo* item = list; item; item = item->ai_next) {
                char buffer[NI_MAXHOST] = {0};
                if (getnameinfo(item->ai_addr, item->ai_addrlen, buffer, sizeof(buffer), NULL, 0, NI_NUMERICHOST) == 0)
                    [addresses addObject:@(buffer)];
            }
            freeaddrinfo(list);
        }
        if (addresses.count) completion(addresses.array, nil);
        else completion(nil, SPDFMacAIWebMakeError(SPDFMacAIWebErrorNotFound, [NSString stringWithFormat:
            @"%@ could not be found. Check the address, or search for the page instead.", name]));
    });
}
@end

// One connection's state, touched only on its queue. The connection's handlers hold it until the connection is
// cancelled, which every ending does.
@interface SPDFMacAIWebExchange : NSObject
@end

@implementation SPDFMacAIWebExchange {
  @public
    nw_connection_t _connection;
    dispatch_queue_t _queue;
    NSData* _request;
    NSString* _name;
    BOOL (^_receive)(NSData*);
    void (^_finished)(NSError*);
    BOOL _done;
}

- (void)finish:(NSError*)error {
    if (_done) return;
    _done = YES;
    void (^finished)(NSError*) = _finished;
    _finished = nil;
    _receive = nil;
    nw_connection_cancel(_connection);
    finished(error);
}

- (NSError*)errorFor:(nw_error_t)error {
    BOOL certificate = error && nw_error_get_error_domain(error) == nw_error_domain_tls;
    NSString* message = certificate ? [NSString stringWithFormat:@"The site's security certificate is not valid "
        "for %@, so the page was not opened.", _name] : @"The site could not be reached.";
    return SPDFMacAIWebMakeError(SPDFMacAIWebErrorUnreachable, message);
}

- (void)receiveNext {
    nw_connection_receive(_connection, 1, 64 * 1024,
                          ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        (void)context;
        if (self->_done) return;
        if (content && !self->_receive((NSData*)content)) { [self finish:nil]; return; }
        if (error) { [self finish:[self errorFor:error]]; return; }
        if (complete) { [self finish:nil]; return; }
        [self receiveNext];
    });
}

- (void)start {
    nw_connection_set_queue(_connection, _queue);
    nw_connection_set_state_changed_handler(_connection, ^(nw_connection_state_t state, nw_error_t error) {
        switch (state) {
            case nw_connection_state_ready: {
                dispatch_data_t bytes = dispatch_data_create(self->_request.bytes, self->_request.length,
                                                             self->_queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                nw_connection_send(self->_connection, bytes, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                                   ^(nw_error_t sendError) {
                    if (sendError) [self finish:[self errorFor:sendError]];
                });
                [self receiveNext];
                break;
            }
            // Waiting means "no route now; retry when the network changes": a page request fails instead.
            case nw_connection_state_waiting:
            case nw_connection_state_failed:
                [self finish:[self errorFor:error]];
                break;
            case nw_connection_state_cancelled:
                [self finish:SPDFMacAIWebMakeError(SPDFMacAIWebErrorCancelled, @"The page request was stopped.")];
                nw_connection_set_state_changed_handler(self->_connection, nil); // releases this exchange
                break;
            default:
                break;
        }
    });
    nw_connection_start(_connection);
}

@end

@implementation SPDFMacAIWebTLSConnector {
    NSString* _Nullable (^_check)(NSString*);
}

- (instancetype)init { return [self initWithAddressCheck:nil]; }

- (instancetype)initWithAddressCheck:(NSString* _Nullable (^)(NSString*))check {
    if (!(self = [super init])) return nil;
    _check = check;
    if (!_check) _check = ^NSString*(NSString* address) { return SPDFMacAIWebAddressRefusal(address); };
    _connectTimeout = 10;
    return self;
}

- (dispatch_block_t)exchangeRequest:(NSData*)request address:(NSString*)address port:(uint16_t)port
                         serverName:(NSString*)serverName queue:(dispatch_queue_t)queue
                            receive:(BOOL (^)(NSData*))receive finished:(void (^)(NSError*))finished {
    NSString* refusal = _check(address);
    if (refusal) {
        dispatch_async(queue, ^{ finished(SPDFMacAIWebMakeError(SPDFMacAIWebErrorPrivateAddress, refusal)); });
        return ^{};
    }
    NSString* name = serverName.length ? serverName : address;
    uint32_t timeout = (uint32_t)MAX(1.0, ceil(_connectTimeout));
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
        if (serverName.length) sec_protocol_options_set_tls_server_name(options, serverName.UTF8String);
        sec_protocol_options_set_min_tls_protocol_version(options, tls_protocol_version_TLSv12);
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1");
        // The endpoint is a number, so the certificate is checked against the name explicitly: connecting to the
        // checked address must not mean accepting any certificate that address presents.
        sec_protocol_options_set_verify_block(options, ^(sec_protocol_metadata_t metadata, sec_trust_t trustRef,
                                                         sec_protocol_verify_complete_t complete) {
            (void)metadata;
            SecTrustRef trust = sec_trust_copy_ref(trustRef);
            SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)name);
            SecTrustSetPolicies(trust, policy);
            CFRelease(policy);
            SecTrustEvaluateAsyncWithError(trust, queue, ^(SecTrustRef evaluated, bool trusted, CFErrorRef error) {
                (void)evaluated; (void)error;
                CFRelease(trust);
                complete(trusted);
            });
        }, queue);
    }, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_connection_timeout(tcp, timeout);
    });
    NSString* service = [NSString stringWithFormat:@"%u", port];
    SPDFMacAIWebExchange* exchange = [SPDFMacAIWebExchange new];
    exchange->_connection = nw_connection_create(nw_endpoint_create_host(address.UTF8String, service.UTF8String),
                                                 parameters);
    exchange->_queue = queue;
    exchange->_request = [request copy];
    exchange->_name = name;
    exchange->_receive = [receive copy];
    exchange->_finished = [finished copy];
    [exchange start];
    return ^{
        dispatch_async(queue, ^{
            [exchange finish:SPDFMacAIWebMakeError(SPDFMacAIWebErrorCancelled, @"The page request was stopped.")];
        });
    };
}

@end
