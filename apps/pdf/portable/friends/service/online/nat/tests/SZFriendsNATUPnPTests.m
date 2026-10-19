// miniupnpc against a scripted IGD on loopback (HTTP description and SOAP control): mapping, stale cleanup, the
// permanent-lease fallback, the IPv6 pinhole, deletes, a control URL on another host, the budget, and the whole
// port-mapping order falling through PCP to UPnP.

#import "SZFriendsNATTestSupport.h"

#import "service/online/nat/SZFriendsNATPortMapping.h"
#import "service/online/nat/SZFriendsNATUPnP.h"

#include <unistd.h>

@interface ScriptedIGD : NSObject
@property(nonatomic, strong) SZFTestTCPServer *server;
@property(nonatomic, strong) NSMutableArray<NSString *> *actions; // "Action k=v k=v"
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *table;
@property(nonatomic) BOOL permanentOnly, withPinholes;
@property(nonatomic, copy) NSString *controlBase; // nil: relative control URLs on the IGD itself
@property(nonatomic) NSTimeInterval addDelay;
@end

static NSString *Field(NSString *body, NSString *name) {
    NSString *open = [NSString stringWithFormat:@"<%@>", name], *close = [NSString stringWithFormat:@"</%@>", name];
    NSRange start = [body rangeOfString:open], end = [body rangeOfString:close];
    if (start.location == NSNotFound || end.location == NSNotFound || end.location < NSMaxRange(start)) return @"";
    return [body substringWithRange:NSMakeRange(NSMaxRange(start), end.location - NSMaxRange(start))];
}

@implementation ScriptedIGD

- (instancetype)init {
    if ((self = [super init])) {
        _actions = [NSMutableArray array];
        _table = [NSMutableArray array];
        __weak ScriptedIGD *weakSelf = self;
        _server = [[SZFTestTCPServer alloc] initWithHost:@"127.0.0.1" handler:^(int fd) {
            [weakSelf serve:fd];
            close(fd);
        }];
    }
    return self;
}

- (NSString *)rootURL {
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/rootDesc.xml", _server.endpoint.port];
}

- (NSArray<NSString *> *)actionsCopy {
    @synchronized(self) {
        return [_actions copy];
    }
}

- (NSString *)description:(NSString *)base {
    NSString *pinholes = _withPinholes ? [NSString stringWithFormat:
        @"<service><serviceType>urn:schemas-upnp-org:service:WANIPv6FirewallControl:1</serviceType>"
         "<serviceId>urn:upnp-org:serviceId:WANIPv6Firewall1</serviceId><controlURL>%@/ctl/IP6FCtl</controlURL>"
         "<eventSubURL>/evt/IP6FCtl</eventSubURL><SCPDURL>/WANIP6FC.xml</SCPDURL></service>", base] : @"";
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><specVersion><major>1</major>"
         "<minor>0</minor></specVersion><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1"
         "</deviceType><friendlyName>Scripted</friendlyName><deviceList><device><deviceType>"
         "urn:schemas-upnp-org:device:WANDevice:1</deviceType><deviceList><device><deviceType>"
         "urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType><serviceList><service><serviceType>"
         "urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><serviceId>urn:upnp-org:serviceId:WANIPConn1"
         "</serviceId><controlURL>%@/ctl/IPConn</controlURL><eventSubURL>/evt/IPConn</eventSubURL>"
         "<SCPDURL>/WANIPCn.xml</SCPDURL></service>%@</serviceList></device></deviceList></device></deviceList>"
         "</device></root>", base, pinholes];
}

static NSString *Envelope(NSString *inner) {
    return [NSString stringWithFormat:@"<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/"
                                       "envelope/\"><s:Body>%@</s:Body></s:Envelope>", inner];
}

static NSString *Fault(int code) {
    return Envelope([NSString stringWithFormat:@"<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError"
                                                "</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:"
                                                "control-1-0\"><errorCode>%d</errorCode><errorDescription>x"
                                                "</errorDescription></UPnPError></detail></s:Fault>", code]);
}

- (NSString *)control:(NSString *)action body:(NSString *)body status:(int *)status {
    NSString *service = @"urn:schemas-upnp-org:service:WANIPConnection:1";
    NSString *(^ok)(NSString *) = ^NSString *(NSString *fields) {
        return Envelope([NSString stringWithFormat:@"<u:%@Response xmlns:u=\"%@\">%@</u:%@Response>", action, service,
                                                   fields, action]);
    };
    @synchronized(self) {
        [_actions addObject:[NSString stringWithFormat:@"%@ ext=%@ int=%@ client=%@ desc=%@ lease=%@", action,
                                                       Field(body, @"NewExternalPort"), Field(body, @"NewInternalPort"),
                                                       Field(body, @"NewInternalClient"),
                                                       Field(body, @"NewPortMappingDescription"),
                                                       Field(body, @"NewLeaseDuration")]];
        if ([action isEqualToString:@"GetExternalIPAddress"]) {
            return ok(@"<NewExternalIPAddress>203.0.113.20</NewExternalIPAddress>");
        }
        if ([action isEqualToString:@"GetGenericPortMappingEntry"]) {
            NSInteger index = Field(body, @"NewPortMappingIndex").integerValue;
            if (index >= (NSInteger)_table.count) {
                *status = 500;
                return Fault(713);
            }
            NSDictionary<NSString *, NSString *> *e = _table[(NSUInteger)index];
            return ok([NSString stringWithFormat:@"<NewRemoteHost></NewRemoteHost><NewExternalPort>%@</NewExternalPort>"
                                                  "<NewProtocol>%@</NewProtocol><NewInternalPort>%@</NewInternalPort>"
                                                  "<NewInternalClient>%@</NewInternalClient><NewEnabled>1</NewEnabled>"
                                                  "<NewPortMappingDescription>%@</NewPortMappingDescription>"
                                                  "<NewLeaseDuration>0</NewLeaseDuration>", e[@"ext"], e[@"proto"],
                                                  e[@"int"], e[@"client"], e[@"desc"]]);
        }
        if ([action isEqualToString:@"DeletePortMapping"]) {
            NSString *ext = Field(body, @"NewExternalPort");
            for (NSDictionary *e in [_table copy]) {
                if ([e[@"ext"] isEqualToString:ext]) [_table removeObject:e];
            }
            return ok(@"");
        }
        if ([action isEqualToString:@"AddPortMapping"]) {
            if (_permanentOnly && ![Field(body, @"NewLeaseDuration") isEqualToString:@"0"]) {
                *status = 500;
                return Fault(725);
            }
            [_table addObject:@{@"ext" : Field(body, @"NewExternalPort"), @"proto" : Field(body, @"NewProtocol"),
                                @"int" : Field(body, @"NewInternalPort"), @"client" : Field(body, @"NewInternalClient"),
                                @"desc" : Field(body, @"NewPortMappingDescription")}];
            return ok(@"");
        }
        if ([action isEqualToString:@"AddPinhole"]) return ok(@"<UniqueID>7</UniqueID>");
        if ([action hasSuffix:@"Pinhole"]) return ok(@"");
    }
    *status = 500;
    return Fault(401);
}

- (void)serve:(int)fd {
    NSData *head = SZFTestReadSocket(fd, 1, 3);
    NSMutableData *request = [head mutableCopy];
    while ([[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] != nil &&
           ![[[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] containsString:@"\r\n\r\n"]) {
        NSData *more = SZFTestReadSocket(fd, 1, 3);
        if (more.length == 0) return;
        [request appendData:more];
    }
    NSString *text = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
    NSRange split = [text rangeOfString:@"\r\n\r\n"];
    NSString *headers = [text substringToIndex:split.location];
    NSInteger length = 0;
    for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
        if ([line.lowercaseString hasPrefix:@"content-length:"]) length = [line substringFromIndex:15].integerValue;
    }
    NSMutableString *body = [[text substringFromIndex:NSMaxRange(split)] mutableCopy];
    if ((NSInteger)body.length < length) {
        NSData *rest = SZFTestReadSocket(fd, (NSUInteger)(length - (NSInteger)body.length), 3);
        [body appendString:[[NSString alloc] initWithData:rest encoding:NSUTF8StringEncoding] ?: @""];
    }
    int status = 200;
    NSString *reply;
    if ([headers hasPrefix:@"GET /rootDesc.xml"]) {
        reply = [self description:_controlBase ?: @""];
    } else {
        NSString *soapAction = @"";
        for (NSString *line in [headers componentsSeparatedByString:@"\r\n"]) {
            NSRange hash = [line rangeOfString:@"#"];
            if ([line.lowercaseString hasPrefix:@"soapaction:"] && hash.location != NSNotFound) {
                soapAction = [[line substringFromIndex:NSMaxRange(hash)]
                    stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
            }
        }
        if ([soapAction isEqualToString:@"AddPortMapping"] && _addDelay > 0) usleep((useconds_t)(_addDelay * 1e6));
        reply = [self control:soapAction body:body status:&status];
    }
    NSData *bytes = [reply dataUsingEncoding:NSUTF8StringEncoding];
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: text/xml; charset=\"utf-8\"\r\n"
                                                     "Content-Length: %lu\r\nConnection: close\r\n\r\n",
                                                     status, status == 200 ? @"OK" : @"Internal Server Error",
                                                     (unsigned long)bytes.length];
    NSMutableData *all = [[response dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [all appendData:bytes];
    write(fd, all.bytes, all.length);
}

@end

typedef struct {
    NSArray<SZFriendsNATEndpoint *> *mapped;
    NSError *error;
} UPnPResult;

static UPnPResult Map(SZFriendsNATUPnP *upnp, uint16_t port, SZFriendsNATEndpoint *ipv6) {
    __block UPnPResult result = {nil, nil};
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [upnp mapUDPPort:port
        localAddress:[SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:0]
          globalIPv6:ipv6
               queue:SZFTestQueue("szf.test.upnp")
          completion:^(NSArray<SZFriendsNATEndpoint *> *mapped, NSError *error) {
              result.mapped = mapped;
              result.error = error;
              dispatch_semaphore_signal(done);
          }];
    CHECK(SZFTestWait(done, upnp.budget + 1), "the UPnP step ends within its budget");
    return result;
}

static void TestMapCleanupPinholeDelete(void) {
    ScriptedIGD *igd = [ScriptedIGD new];
    igd.withPinholes = YES;
    [igd.table addObject:@{@"ext" : @"45555", @"proto" : @"UDP", @"int" : @"45555", @"client" : @"127.0.0.1",
                           @"desc" : @"Shenzhen Friends"}];
    [igd.table addObject:@{@"ext" : @"8080", @"proto" : @"TCP", @"int" : @"8080", @"client" : @"127.0.0.1",
                           @"desc" : @"Another app"}];
    SZFriendsNATUPnP *upnp = [SZFriendsNATUPnP deviceAtRootDescriptionURL:igd.rootURL];
    SZFriendsNATEndpoint *ipv6 = [SZFriendsNATEndpoint endpointWithHost:@"2400:cb00::7" port:0];
    UPnPResult result = Map(upnp, 45000, ipv6);
    CHECK(result.error == nil && result.mapped.count == 2 && upnp.foundDevice, "%@", result.error);
    CHECK([result.mapped.firstObject isEqual:[SZFriendsNATEndpoint endpointWithHost:@"203.0.113.20" port:45000]]);
    CHECK([result.mapped.lastObject isEqual:[ipv6 endpointWithPort:45000]], "the IPv6 pinhole");
    NSArray<NSString *> *actions = igd.actionsCopy;
    CHECK([actions containsObject:@"DeletePortMapping ext=45555 int= client= desc= lease="], "a crashed run's mapping");
    CHECK([actions containsObject:@"AddPortMapping ext=45000 int=45000 client=127.0.0.1 desc=Shenzhen Friends "
                                  @"lease=7200"], "%@", actions);
    CHECK(igd.table.count == 2 && [igd.table.firstObject[@"desc"] isEqualToString:@"Another app"],
          "another application's mapping stays");
    [upnp removeMappings];
    usleep(300 * 1000);
    actions = igd.actionsCopy;
    CHECK([actions containsObject:@"DeletePortMapping ext=45000 int= client= desc= lease="] &&
          [[actions filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'DeletePinhole'"]]
              count] == 1, "removed on close: %@", actions);
    [igd.server close];
}

static void TestPermanentLeaseAndForeignControl(void) {
    ScriptedIGD *igd = [ScriptedIGD new];
    igd.permanentOnly = YES;
    SZFriendsNATUPnP *upnp = [SZFriendsNATUPnP deviceAtRootDescriptionURL:igd.rootURL];
    UPnPResult result = Map(upnp, 46000, nil);
    CHECK(result.mapped.count == 1, "mapped with an infinite lease");
    CHECK([igd.actionsCopy containsObject:@"AddPortMapping ext=46000 int=46000 client=127.0.0.1 desc=Shenzhen Friends "
                                          @"lease=0"]);
    [upnp removeMappings];
    [igd.server close];

    ScriptedIGD *redirecting = [ScriptedIGD new];
    redirecting.controlBase = @"http://192.0.2.1:80"; // a device sending us to post somewhere else
    upnp = [SZFriendsNATUPnP deviceAtRootDescriptionURL:redirecting.rootURL];
    result = Map(upnp, 46001, nil);
    CHECK(result.mapped.count == 0 && result.error != nil && !upnp.foundDevice, "a control URL off the device");
    CHECK(redirecting.actionsCopy.count == 0, "nothing was posted");
    [redirecting.server close];
    CHECK([SZFriendsNATUPnP deviceAtRootDescriptionURL:@"http://example.com/rootDesc.xml"] != nil);
    result = Map([SZFriendsNATUPnP deviceAtRootDescriptionURL:@"http://192.0.2.1/rootDesc.xml"], 46002, nil);
    CHECK(result.mapped.count == 0, "a test device off loopback is refused before any connection");
}

static void TestBudget(void) {
    ScriptedIGD *igd = [ScriptedIGD new];
    igd.addDelay = 1.5;
    SZFriendsNATUPnP *upnp = [SZFriendsNATUPnP deviceAtRootDescriptionURL:igd.rootURL];
    upnp.budget = 1;
    NSDate *start = [NSDate date];
    UPnPResult result = Map(upnp, 47000, nil);
    CHECK(result.error.code == SZFriendsNATErrorTimedOut && -start.timeIntervalSinceNow < 1.4, "the budget holds");
    usleep(1500 * 1000);
    CHECK([igd.actionsCopy containsObject:@"DeletePortMapping ext=47000 int= client= desc= lease="] &&
          igd.table.count == 0, "a mapping made after the budget is deleted at once: %@", igd.actionsCopy);
    [igd.server close];
}

@interface UPnPRecorder : NSObject <SZFriendsNATPortMappingDelegate>
@property(nonatomic) SZFriendsNATMappingProtocol protocol;
@property(nonatomic) NSUInteger mapped;
@property(nonatomic, strong) dispatch_semaphore_t finish;
@end

@implementation UPnPRecorder
- (void)portMapping:(SZFriendsNATPortMapping *)m
     didMapExternal:(SZFriendsNATEndpoint *)e
           protocol:(SZFriendsNATMappingProtocol)p {
    (void)m, (void)e;
    _protocol = p;
}
- (void)portMapping:(SZFriendsNATPortMapping *)m didLoseExternal:(SZFriendsNATEndpoint *)e {
    (void)m, (void)e;
}
- (void)portMapping:(SZFriendsNATPortMapping *)m didFinishWithMappings:(NSUInteger)mapped {
    (void)m;
    _mapped = mapped;
    dispatch_semaphore_signal(_finish);
}
@end

static void TestOrderFallsThroughToUPnP(void) {
    ScriptedIGD *igd = [ScriptedIGD new];
    SZFTestUDPHandler silent = ^NSArray<NSData *> *(NSData *p, SZFriendsNATEndpoint *f) {
        (void)p, (void)f;
        return @[];
    };
    SZFTestUDPServer *closed = [[SZFTestUDPServer alloc] initWithHost:@"127.0.0.1" port:0 handler:silent];
    SZFriendsNATEndpoint *gateway = closed.endpoint;
    [closed close]; // port unreachable: no PCP, no NAT-PMP
    usleep(50 * 1000);
    SZFriendsNATPortMappingConfiguration *configuration = [SZFriendsNATPortMappingConfiguration new];
    configuration.internalPort = 48000;
    configuration.gatewayIPv4 = gateway;
    configuration.serverPort = gateway.port;
    configuration.loopbackOnly = YES;
    configuration.upnp = [SZFriendsNATUPnP deviceAtRootDescriptionURL:igd.rootURL];
    UPnPRecorder *recorder = [UPnPRecorder new];
    recorder.finish = dispatch_semaphore_create(0);
    dispatch_queue_t queue = SZFTestQueue("szf.test.order");
    SZFriendsNATPortMapping *mapping = [[SZFriendsNATPortMapping alloc] initWithConfiguration:configuration
                                                                                     delegate:recorder
                                                                                        queue:queue];
    SZFTestSync(queue, ^{
        [mapping start];
    });
    CHECK(SZFTestWait(recorder.finish, 5) && recorder.mapped == 1, "PCP refused, so UPnP mapped it");
    CHECK(recorder.protocol == SZFriendsNATMappingProtocolUPnP);
    CHECK(mapping.gatewayRefusedPort && !mapping.fellBackToNATPMP);
    SZFTestSync(queue, ^{
        [mapping close];
    });
    usleep(300 * 1000);
    CHECK(igd.table.count == 0, "close deleted the UPnP mapping");
    [igd.server close];
}

void SZFTestUPnP(void) {
    TestMapCleanupPinholeDelete();
    TestPermanentLeaseAndForeignControl();
    TestBudget();
    TestOrderFallsThroughToUPnP();
}
