// The technique log (SZFriendsOnlineOrder.h; ADR 0011 § Technique log).

#import "service/online/order/SZFriendsOnlineOrder.h"

#pragma mark - Log entries

// Every key an entry has, with the largest value it may hold. Nothing else is written or read back.
static NSDictionary<NSString *, NSNumber *> *EntryLimits(void) {
    static NSDictionary<NSString *, NSNumber *> *limits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        limits = @{
            @"purpose" : @(SZFriendsOnlinePurposeLink),
            @"role" : @(SZFriendsOnlineRoleAnswerer),
            @"local_nat" : @(SZFriendsNATClassPerDestination),
            @"remote_nat" : @(SZFriendsNATClassPerDestination),
            @"tried" : @((1u << (SZFriendsOnlineTechniqueRelay + 1)) - 2),
            @"first" : @(SZFriendsOnlineTechniqueRelay),
            @"final" : @(SZFriendsOnlineTechniqueRelay),
            @"seconds_to_first_stream" : @(86400),
            @"relay_requested" : @1,
            @"relay_needed" : @1,
            @"left_relay" : @1,
            @"direct_retries" : @(1000000),
            @"end" : @(SZFriendsOnlineEndStreamClosed),
        };
    });
    return limits;
}

@implementation SZFriendsTechniqueLogEntry

- (instancetype)init {
    if ((self = [super init])) _secondsToFirstStream = -1;
    return self;
}

- (NSDictionary<NSString *, NSNumber *> *)propertyList {
    // Whole tenths of a second are enough for the support matrix and keep the JSON short.
    double seconds = self.secondsToFirstStream < 0 ? -1 : round(MIN(self.secondsToFirstStream, 86400) * 10) / 10;
    return @{
        @"purpose" : @(self.purpose),
        @"role" : @(self.role),
        @"local_nat" : @(self.localNATClass),
        @"remote_nat" : @(self.remoteNATClass),
        @"tried" : @(self.techniquesTried),
        @"first" : @(self.firstTechnique),
        @"final" : @(self.finalTechnique),
        @"seconds_to_first_stream" : @(seconds),
        @"relay_requested" : @(self.relayRequested ? 1 : 0),
        @"relay_needed" : @(self.relayNeeded ? 1 : 0),
        @"left_relay" : @(self.leftRelay ? 1 : 0),
        @"direct_retries" : @(MIN(self.directRetries, (NSUInteger)1000000)),
        @"end" : @(self.endReason),
    };
}

+ (instancetype)entryWithPropertyList:(id)propertyList {
    if (![propertyList isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dictionary = propertyList;
    NSDictionary<NSString *, NSNumber *> *limits = EntryLimits();
    if (![[NSSet setWithArray:dictionary.allKeys] isEqualToSet:[NSSet setWithArray:limits.allKeys]]) return nil;
    for (NSString *key in limits) {
        NSNumber *value = dictionary[key];
        if (![value isKindOfClass:[NSNumber class]] || !isfinite(value.doubleValue)) return nil;
        double lowest = [key isEqualToString:@"seconds_to_first_stream"] ? -1 : 0;
        if (value.doubleValue < lowest || value.doubleValue > limits[key].doubleValue) return nil;
        BOOL whole = value.doubleValue == floor(value.doubleValue);
        if (!whole && ![key isEqualToString:@"seconds_to_first_stream"]) return nil;
    }
    SZFriendsTechniqueLogEntry *entry = [self new];
    entry.purpose = [dictionary[@"purpose"] integerValue];
    entry.role = [dictionary[@"role"] integerValue];
    entry.localNATClass = [dictionary[@"local_nat"] integerValue];
    entry.remoteNATClass = [dictionary[@"remote_nat"] integerValue];
    entry.techniquesTried = [dictionary[@"tried"] unsignedIntegerValue];
    entry.firstTechnique = [dictionary[@"first"] integerValue];
    entry.finalTechnique = [dictionary[@"final"] integerValue];
    entry.secondsToFirstStream = [dictionary[@"seconds_to_first_stream"] doubleValue];
    entry.relayRequested = [dictionary[@"relay_requested"] boolValue];
    entry.relayNeeded = [dictionary[@"relay_needed"] boolValue];
    entry.leftRelay = [dictionary[@"left_relay"] boolValue];
    entry.directRetries = [dictionary[@"direct_retries"] unsignedIntegerValue];
    entry.endReason = [dictionary[@"end"] integerValue];
    return entry;
}

@end

#pragma mark - The log

@implementation SZFriendsTechniqueLog {
    NSUInteger _capacity;
    NSMutableArray<SZFriendsTechniqueLogEntry *> *_entries;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = MAX(capacity, (NSUInteger)1);
        _entries = [NSMutableArray array];
    }
    return self;
}

- (nullable instancetype)initWithJSONData:(NSData *)data capacity:(NSUInteger)capacity {
    id array = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![array isKindOfClass:[NSArray class]]) return nil;
    if ((self = [self initWithCapacity:capacity])) {
        for (id item in array) {
            SZFriendsTechniqueLogEntry *entry = [SZFriendsTechniqueLogEntry entryWithPropertyList:item];
            if (entry) [self appendEntry:entry];
        }
    }
    return self;
}

- (void)appendEntry:(SZFriendsTechniqueLogEntry *)entry {
    // Kept as its property list's reading, so what is held is exactly what would be written.
    SZFriendsTechniqueLogEntry *copy = [SZFriendsTechniqueLogEntry entryWithPropertyList:[entry propertyList]];
    if (copy == nil) return;
    [_entries addObject:copy];
    if (_entries.count > _capacity) [_entries removeObjectsInRange:NSMakeRange(0, _entries.count - _capacity)];
}

- (NSArray<SZFriendsTechniqueLogEntry *> *)entries {
    return [_entries copy];
}

- (NSData *)JSONData {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:_entries.count];
    for (SZFriendsTechniqueLogEntry *entry in _entries) [list addObject:[entry propertyList]];
    return [NSJSONSerialization dataWithJSONObject:list options:NSJSONWritingSortedKeys error:NULL] ?: [NSData data];
}

@end
