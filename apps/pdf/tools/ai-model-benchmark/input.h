// Offline validation happens before credentials or requests are touched.
static NSDictionary *Dictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
static NSArray *Array(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
static NSString *String(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static BOOL NonemptyString(id value) {
    return String(value).length > 0;
}
static BOOL ValidNumber(id value, double minimum, double maximum) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
           [value doubleValue] >= minimum && [value doubleValue] <= maximum;
}
static BOOL ValidMetadata(id value) {
    return [value isKindOfClass:NSDictionary.class] &&
           (!value[@"analysis"] || [value[@"analysis"] isKindOfClass:NSDictionary.class]);
}
static NSString *ValidateManifest(id input) {
    if (![input isKindOfClass:NSArray.class] && ![input isKindOfClass:NSDictionary.class])
        return @"Expected a case array or an object containing cases.";
    NSDictionary *config = Dictionary(input);
    id cases = [input isKindOfClass:NSArray.class] ? input : config[@"cases"];
    if (![cases isKindOfClass:NSArray.class] || ![cases count])
        return @"Cases must be a nonempty array.";
    if (config[@"costCapUSD"] &&
        (!ValidNumber(config[@"costCapUSD"], 0, 2) || [config[@"costCapUSD"] doubleValue] == 0))
        return @"costCapUSD must be a finite number greater than zero and at most 2.";
    for (id item in cases) {
        if (![item isKindOfClass:NSDictionary.class])
            return @"Each case must be an object.";
        NSDictionary *test = item;
        for (NSString *field in @[ @"name", @"path", @"question", @"model" ])
            if (!NonemptyString(test[field]))
                return @"Case name, path, question and model must be nonempty strings.";
        if (![test[@"path"] isAbsolutePath])
            return @"The active source path must be absolute.";
        if (test[@"paths"]) {
            if (![test[@"paths"] isKindOfClass:NSArray.class] || ![test[@"paths"] count])
                return @"paths must be a nonempty array.";
            for (id path in test[@"paths"])
                if (!NonemptyString(path) || ![path isAbsolutePath])
                    return @"Each source path must be an absolute string.";
        }
        if (test[@"repeat"] && (!ValidNumber(test[@"repeat"], 1, 1000000) ||
                                floor([test[@"repeat"] doubleValue]) != [test[@"repeat"] doubleValue]))
            return @"repeat must be a positive integer.";
        if (test[@"metadata"] && !ValidMetadata(test[@"metadata"]))
            return @"metadata must be an object with an optional analysis object.";
        if (test[@"metadataByPath"]) {
            if (![test[@"metadataByPath"] isKindOfClass:NSDictionary.class])
                return @"metadataByPath must be an object.";
            for (NSString *path in test[@"metadataByPath"])
                if (!path.isAbsolutePath || !ValidMetadata(test[@"metadataByPath"][path]))
                    return @"metadataByPath needs absolute keys and metadata object values.";
        }
    }
    return nil;
}
