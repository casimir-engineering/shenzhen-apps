// Every animal the golden fixtures reference resolves in the bundled set, with the color the fixture carries, and
// SZFriendsPicture produces exactly those avatar fields.

#import "SZFriendsAvatarsTestSupport.h"

static void SZTestCollectAnimals(id node, NSString *where, NSMutableArray<NSDictionary *> *found) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *object = node;
        if ([object[@"kind"] isEqual:@"animal"] && object[@"index"] != nil) {
            [found addObject:@{@"where" : where, @"object" : object}];
        }
        for (NSString *key in object) {
            SZTestCollectAnimals(object[key], [where stringByAppendingFormat:@".%@", key], found);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        NSArray *array = node;
        for (NSUInteger i = 0; i < array.count; i++) {
            SZTestCollectAnimals(array[i], [where stringByAppendingFormat:@"[%lu]", (unsigned long)i], found);
        }
    }
}

void SZRunFixtureReferenceTests(SZTestContext context) {
    SZFriendsAnimalSet *set = [SZFriendsAnimalSet setWithManifestAtPath:context.manifestPath error:NULL];
    SZ_CHECK(set != nil, @"manifest");
    if (!set) return;

    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtPath:context.fixturesPath];
    for (NSString *relative in files) {
        NSString *path = [context.fixturesPath stringByAppendingPathComponent:relative];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if ([relative hasSuffix:@".json"]) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            SZ_CHECK(json != nil, @"%@ is not JSON", relative);
            SZTestCollectAnimals(json, relative, found);
        } else if ([relative hasSuffix:@".jsonl"]) {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSUInteger line = 0;
            for (NSString *row in [text componentsSeparatedByString:@"\n"]) {
                line++;
                if (row.length == 0) continue;
                id json = [NSJSONSerialization JSONObjectWithData:[row dataUsingEncoding:NSUTF8StringEncoding]
                                                          options:0
                                                            error:NULL];
                SZTestCollectAnimals(json, [NSString stringWithFormat:@"%@:%lu", relative, (unsigned long)line], found);
            }
        }
    }

    NSMutableSet<NSNumber *> *indexes = [NSMutableSet set];
    for (NSDictionary *entry in found) {
        NSDictionary *object = entry[@"object"];
        NSInteger version = [object[@"set"] integerValue], index = [object[@"index"] integerValue];
        [indexes addObject:@(index)];
        SZ_CHECK(version == set.version && [set containsIndex:index], @"%@: animal %ld/%ld is not in the set",
                 entry[@"where"], (long)version, (long)index);
        if (object[@"color"]) {
            SZ_CHECK([object[@"color"] isEqual:[set colorAtIndex:index]], @"%@: color %@, the set says %@",
                     entry[@"where"], object[@"color"], [set colorAtIndex:index]);
            // The avatar object the presentation layer will build from this picture matches the fixture, apart
            // from the initials it adds itself.
            NSMutableDictionary *expected = [object mutableCopy];
            [expected removeObjectForKey:@"initials"];
            NSDictionary *fields = [[SZFriendsPicture animalWithSet:version index:index]
                protocolFieldsValidatedAgainst:set];
            SZ_CHECK([fields isEqualToDictionary:expected], @"%@: %@ != %@", entry[@"where"], fields, expected);
        }
    }
    // Guards the walk itself: README.md lists the indexes the fixtures use, so finding fewer means it broke.
    NSSet *listed = [NSSet setWithArray:@[ @0, @1, @3, @4, @5, @7, @9, @10, @11 ]];
    SZ_CHECK([indexes isEqualToSet:listed], @"fixtures reference animals %@", indexes);
    SZ_CHECK(found.count >= 30, @"only %lu animal references found", (unsigned long)found.count);
}
