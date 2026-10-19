#import "SPDFMacAIOpenRouterAuth.h"
#import "SPDFMacAICredentials.h"
#import "SPDFMacAITransport.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString* Base64URL(NSData* bytes) {
    return [[[[bytes base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
NSString* SPDFMacAIPKCEChallenge(NSString* verifier) {
    NSData* input=[verifier dataUsingEncoding:NSUTF8StringEncoding]; uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes,(CC_LONG)input.length,digest); return Base64URL([NSData dataWithBytes:digest length:sizeof(digest)]);
}
static NSString* RandomToken(void) {
    uint8_t bytes[32]; if(SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess)return nil;
    return Base64URL([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}
@interface SPDFMacAIOpenRouterAuth () <NSURLSessionDataDelegate>
@property(nonatomic) NSURLSessionConfiguration* configuration;
@property(nonatomic) SPDFMacAICredentials* credentials;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t listener;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) NSURLSession* session;
@property(nonatomic) NSMutableData* response;
@property(nonatomic) NSInteger status;
@property(nonatomic) NSString* verifier;
@property(nonatomic) NSString* state;
@property(nonatomic) NSString* callbackPath;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL exchanging;
@property(nonatomic,copy) void (^completion)(BOOL,NSError*);
@end
@implementation SPDFMacAIOpenRouterAuth
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration*)configuration credentials:(SPDFMacAICredentials*)credentials {
    if((self=[super init])) { _configuration=[configuration copy]; _credentials=credentials; } return self;
}
- (NSURL*)startWithCompletion:(void (^)(BOOL,NSError*))completion error:(NSError**)error {
    if(error)*error=nil;
    if(self.queue) { if(error)*error=SPDFMacAIError(40,@"This connection request has already started."); return nil; }
    self.verifier=RandomToken(); self.state=RandomToken();
    if(!self.verifier || !self.state) { if(error)*error=SPDFMacAIError(41,@"Secure sign-in could not start."); return nil; }
    int socketFD=socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address={}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(socketFD<0 || bind(socketFD,(struct sockaddr*)&address,sizeof(address))!=0 || listen(socketFD,4)!=0) {
        if(socketFD>=0)close(socketFD); if(error)*error=SPDFMacAIError(42,@"Cannot start browser sign-in. Use an API key instead."); return nil;
    }
    socklen_t length=sizeof(address); getsockname(socketFD,(struct sockaddr*)&address,&length);
    fcntl(socketFD,F_SETFL,fcntl(socketFD,F_GETFL)|O_NONBLOCK);
    self.queue=dispatch_queue_create("com.intuition.shenzhenpdf.openrouter-auth",DISPATCH_QUEUE_SERIAL);
    self.callbackPath=[@"/callback/" stringByAppendingString:RandomToken()]; self.completion=completion;
    self.listener=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)socketFD,0,self.queue);
    __weak SPDFMacAIOpenRouterAuth* weakSelf=self;
    dispatch_source_set_event_handler(self.listener,^{ [weakSelf acceptCallback:socketFD]; });
    dispatch_source_set_cancel_handler(self.listener,^{ close(socketFD); }); dispatch_resume(self.listener);
    self.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
    dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,5*60*NSEC_PER_SEC),DISPATCH_TIME_FOREVER,NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.timer,^{ [weakSelf finish:NO error:SPDFMacAIError(43,@"Sign-in timed out. Try connecting again.")]; });
    dispatch_resume(self.timer);
    NSString* callback=[NSString stringWithFormat:@"http://localhost:%u%@",ntohs(address.sin_port),self.callbackPath];
    NSURLComponents* URL=[NSURLComponents componentsWithString:@"https://openrouter.ai/auth"];
    URL.queryItems=@[[NSURLQueryItem queryItemWithName:@"callback_url" value:callback],
        [NSURLQueryItem queryItemWithName:@"state" value:self.state],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:SPDFMacAIPKCEChallenge(self.verifier)],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"key_label" value:@"Shenzhen PDF"]]; return URL.URL;
}
- (void)acceptCallback:(int)socketFD {
    int client=accept(socketFD,NULL,NULL); if(client<0)return;
    fcntl(client,F_SETFL,fcntl(client,F_GETFL)&~O_NONBLOCK);
    // Each local request is bounded in size and time; an unrelated browser probe must not consume the session.
    struct timeval timeout={1,0}; setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    int yes=1; setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    char buffer[8192]; ssize_t total=0;
    while(total<(ssize_t)sizeof(buffer)) {
        ssize_t n=recv(client,buffer+total,sizeof(buffer)-(size_t)total,0); if(n<=0)break; total+=n;
        if(total>=4 && memmem(buffer,(size_t)total,"\r\n\r\n",4))break;
    }
    NSString* request=total>0 ? [[NSString alloc] initWithBytes:buffer length:(NSUInteger)total encoding:NSUTF8StringEncoding] : nil;
    NSArray* words=[[request componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    NSURLComponents* URL=words.count==3 && [words[0] isEqual:@"GET"] ?
        [NSURLComponents componentsWithString:[@"http://localhost" stringByAppendingString:words[1]]] : nil;
    NSMutableDictionary* query=[NSMutableDictionary dictionary]; BOOL duplicate=NO;
    for(NSURLQueryItem* item in URL.queryItems) { if(query[item.name])duplicate=YES; query[item.name]=item.value ?: @""; }
    BOOL pendingCallback=!self.finished && !self.exchanging && !duplicate && [URL.path isEqual:self.callbackPath];
    BOOL valid=pendingCallback && [query[@"state"] isEqual:self.state] &&
        [query[@"code"] length]>0 && [query[@"code"] length]<=4096;
    // OpenRouter's Deny returns to the exact random callback path with no
    // query. It can cancel this attempt, but never exchange or save a key.
    BOOL denied=pendingCallback && !URL.query.length;
    NSString* body=denied ? @"Connection cancelled. Return to Shenzhen PDF; you can connect again any time." :
        valid ? @"Sign-in received. Return to Shenzhen PDF to finish connecting." :
        @"This sign-in response is invalid or expired. Return to Shenzhen PDF and try again.";
    NSString* reply=[NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: %lu\r\n\r\n%@",
        (valid || denied) ? @"200 OK" : @"400 Bad Request",(unsigned long)[body lengthOfBytesUsingEncoding:NSUTF8StringEncoding],body];
    NSData* replyData=[reply dataUsingEncoding:NSUTF8StringEncoding]; send(client,replyData.bytes,replyData.length,0); close(client);
    if(denied) { [self finish:NO error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]]; return; }
    if(!valid)return;
    self.exchanging=YES; dispatch_source_cancel(self.listener); self.listener=nil;
    NSMutableURLRequest* exchange=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://openrouter.ai/api/v1/auth/keys"]];
    exchange.HTTPMethod=@"POST"; [exchange setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    exchange.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"code":query[@"code"],@"code_verifier":self.verifier,
        @"code_challenge_method":@"S256"} options:0 error:nil];
    NSURLSessionConfiguration* config=self.configuration ? [self.configuration copy] : NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache=nil; config.HTTPCookieStorage=nil; config.URLCredentialStorage=nil;
    config.timeoutIntervalForRequest=30; config.timeoutIntervalForResource=45;
    self.response=[NSMutableData data]; NSOperationQueue* operations=[NSOperationQueue new];
    operations.maxConcurrentOperationCount=1; operations.underlyingQueue=self.queue;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:operations];
    [[self.session dataTaskWithRequest:exchange] resume];
}
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
 willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request
 completionHandler:(void (^)(NSURLRequest*))completionHandler {
    (void)session;(void)task;(void)response;(void)request; completionHandler(nil);
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task
 didReceiveResponse:(NSURLResponse*)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session;(void)task; self.status=[response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
    completion(response.expectedContentLength>65536 ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task didReceiveData:(NSData*)data {
    (void)session; if(self.response.length+data.length>65536) { [task cancel]; return; } [self.response appendData:data];
}
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
    (void)session;(void)task;
    dispatch_async(self.queue,^{
        if(self.finished)return;
        id JSON=!error && self.status>=200 && self.status<300 ? [NSJSONSerialization JSONObjectWithData:self.response options:0 error:nil] : nil;
        NSString* key=[JSON isKindOfClass:NSDictionary.class] ? JSON[@"key"] : nil;
        NSError* failure=nil; BOOL saved=self.credentials ? [self.credentials storeAPIKey:key error:&failure] :
            [SPDFMacAICredentials storeAPIKey:key error:&failure];
        [self finish:saved error:saved ? nil : (failure ?: SPDFMacAIError(44,@"OpenRouter sign-in failed. Try again."))];
    });
}
- (void)finish:(BOOL)success error:(NSError*)error {
    if(self.finished)return; self.finished=YES;
    if(self.listener)dispatch_source_cancel(self.listener); self.listener=nil;
    if(self.timer)dispatch_source_cancel(self.timer); self.timer=nil;
    [self.session invalidateAndCancel]; self.session=nil; self.verifier=nil; self.state=nil; self.response=nil;
    void (^completion)(BOOL,NSError*)=self.completion; self.completion=nil;
    if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(success,error);});
}
- (void)cancel {
    if(!self.queue)return;
    dispatch_async(self.queue,^{ [self finish:NO error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]]; });
}
- (BOOL)isAwaitingBrowser {
    dispatch_queue_t queue=self.queue; if(!queue)return NO;
    __block BOOL awaiting=NO;
    dispatch_sync(queue,^{ awaiting=!self.finished && !self.exchanging; });
    return awaiting;
}
- (void)dealloc {
    if(_listener)dispatch_source_cancel(_listener); if(_timer)dispatch_source_cancel(_timer); [_session invalidateAndCancel];
}
@end
