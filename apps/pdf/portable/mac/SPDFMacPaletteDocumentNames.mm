#import "SPDFMacPaletteDocumentNames.h"

static NSString* Text(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString* PathKey(NSString* path) {
    NSString* key = path.stringByStandardizingPath;
    return key.length ? key : (path ?: @"");
}
static BOOL Within(NSString* path, NSString* root) {
    return root.length > 1 && ([path isEqualToString:root] || [path hasPrefix:[root stringByAppendingString:@"/"]]);
}
static NSString* Collapsed(NSString* text) {
    NSArray* words = [Text(text) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
}

NSString* spdf_palette_file_display_name(NSString* path) {
    NSString* name = Text(path).lastPathComponent ?: @"";
    NSString* extension = name.pathExtension;
    if (!extension.length || extension.length > 8 || name.length <= extension.length + 1) return name;
    BOOL letter = NO;
    for (NSUInteger i = 0; i < extension.length; ++i) {
        unichar c = [extension characterAtIndex:i];
        if (c > 127 || !isalnum((int)c)) return name;
        if (isalpha((int)c)) letter = YES;
    }
    return letter ? name.stringByDeletingPathExtension : name;
}

BOOL spdf_palette_name_is_opaque(NSString* name) {
    NSString* stem = spdf_palette_file_display_name(name);
    NSUInteger digits = 0, hex = 0, other = 0;
    for (NSUInteger i = 0; i < stem.length; ++i) {
        unichar c = [stem characterAtIndex:i];
        if (c >= '0' && c <= '9') digits++;
        else if ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) hex++;
        else if (c != '-' && c != '_' && c != '.') other++;
    }
    NSUInteger significant = digits + hex + other;
    if (significant < 12) return NO;
    if (other == 0 && digits >= 3) return YES; // digests and UUIDs
    if ([stem rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) return NO;
    return digits * 10 >= significant * 6;      // export and message ids
}

NSString* spdf_palette_document_title(NSString* path, NSString* label, NSString* metadataTitle) {
    NSString* explicitLabel = Collapsed(label);
    if (explicitLabel.length) return explicitLabel;
    NSString* name = spdf_palette_file_display_name(path);
    if (spdf_palette_name_is_opaque(name)) {
        NSString* title = Collapsed(metadataTitle);
        NSArray* empty = @[@"untitled", @"untitled document", @"title", @"document", @"none"];
        if (title.length >= 2 && title.length <= 160 && !spdf_palette_name_is_opaque(title) &&
            [title caseInsensitiveCompare:name] != NSOrderedSame &&
            [title caseInsensitiveCompare:Text(path).lastPathComponent ?: @""] != NSOrderedSame &&
            ![empty containsObject:title.lowercaseString])
            return title;
    }
    return name.length ? name : (Text(path).lastPathComponent ?: @"");
}

NSString* spdf_palette_collection_copy_document_id(NSString* path) {
    NSArray<NSString*>* parts = Text(path).stringByStandardizingPath.pathComponents;
    NSUInteger count = parts.count;
    if (count < 5 || ![parts[count - 4] isEqualToString:@"editable"]) return nil;
    if (![[NSUUID alloc] initWithUUIDString:parts[count - 3]] || ![[NSUUID alloc] initWithUUIDString:parts[count - 2]])
        return nil;
    return parts[count - 3];
}

static NSString* AppNameForContainer(NSString* bundleID) {
    NSDictionary* known = @{@"com.apple.safari" : @"Safari", @"com.apple.mail" : @"Mail",
                            @"com.tencent.xinwechat" : @"WeChat", @"com.apple.preview" : @"Preview",
                            @"com.apple.mobilesms" : @"Messages", @"com.microsoft.outlook" : @"Outlook"};
    NSString* name = known[bundleID.lowercaseString];
    if (name) return name;
    NSString* last = [bundleID componentsSeparatedByString:@"."].lastObject;
    return last.length ? last : bundleID;
}

// Build and export folders say nothing about which project a file belongs to.
static BOOL GenericFolder(NSString* name) {
    static NSSet* generic;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      generic = [NSSet setWithArray:@[@"pdf", @"pdfs", @"output", @"outputs", @"out", @"export", @"exports",
                                      @"build", @"dist", @"tmp", @"temp", @"files", @"file"]];
    });
    return [generic containsObject:name.lowercaseString];
}

NSString* spdf_palette_location_label(NSString* path, NSString* home, NSString* supportDirectory) {
    NSString* file = Text(path).stringByStandardizingPath;
    if (!file.length) return @"";
    if (spdf_palette_collection_copy_document_id(file)) return @"Collection";
    NSString* folder = file.stringByDeletingLastPathComponent;
    NSString* support = Text(supportDirectory).stringByStandardizingPath;
    if (Within(folder, support)) {
        NSString* area = [folder substringFromIndex:MIN(folder.length, support.length + 1)].pathComponents.firstObject;
        if ([area isEqualToString:@"Collection"]) return @"Collection";
        if ([area isEqualToString:@"Pasted Images"]) return @"Pasted images";
        return @"ShenzhenPDF";
    }
    NSString* homeRoot = Text(home).stringByStandardizingPath;
    NSString* containers = [homeRoot stringByAppendingPathComponent:@"Library/Containers"];
    if (homeRoot.length && Within(folder, containers) && folder.length > containers.length + 1) {
        NSString* bundleID = [folder substringFromIndex:containers.length + 1].pathComponents.firstObject;
        if (bundleID.length) return AppNameForContainer(bundleID);
    }
    NSString* iCloud = [homeRoot stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs"];
    if (homeRoot.length && [folder isEqualToString:iCloud]) return @"iCloud Drive";
    for (NSString* temporary in @[@"/private/var/folders", @"/var/folders", @"/private/tmp", @"/tmp"])
        if (Within(folder, temporary)) return @"Temporary folder";
    if (homeRoot.length && [folder isEqualToString:homeRoot]) return @"Home";
    NSString* candidate = folder;
    for (NSUInteger level = 0; level < 3; ++level) {
        if (!GenericFolder(candidate.lastPathComponent)) return candidate.lastPathComponent;
        NSString* up = candidate.stringByDeletingLastPathComponent;
        if (up.length <= 1 || [up isEqualToString:homeRoot] || [up isEqualToString:candidate]) break;
        candidate = up;
    }
    NSString* name = folder.lastPathComponent;
    return [name isEqualToString:@"/"] ? @"" : (name ?: @"");
}

static double Number(id value) { return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0; }

static NSMutableDictionary* MergedRow(NSMutableDictionary* kept, NSMutableDictionary* row) {
    BOOL keptCopy = spdf_palette_collection_copy_document_id(Text(kept[@"path"])) != nil;
    BOOL rowCopy = spdf_palette_collection_copy_document_id(Text(row[@"path"])) != nil;
    BOOL keptLive = [kept[@"_live"] boolValue], rowLive = [row[@"_live"] boolValue];
    BOOL replace = keptLive != rowLive ? rowLive : (keptCopy && !rowCopy);
    NSMutableDictionary* winner = replace ? row : kept;
    NSMutableDictionary* loser = replace ? kept : row;
    NSMutableArray* merged = [NSMutableArray arrayWithObject:Text(loser[@"path"])];
    for (NSArray* list in @[winner[@"mergedPaths"] ?: @[], loser[@"mergedPaths"] ?: @[]])
        [merged addObjectsFromArray:list];
    winner[@"mergedPaths"] = merged;
    for (NSString* field in @[@"lastViewedAt", @"focusedAt"])
        if (Number(loser[field]) > Number(winner[field])) winner[field] = loser[field];
    if (loser[@"_order"] && Number(loser[@"_order"]) < Number(winner[@"_order"])) winner[@"_order"] = loser[@"_order"];
    for (NSString* field in @[@"group", @"_current"]) if (!winner[field] && loser[field]) winner[field] = loser[field];
    if (!spdf_palette_collection_copy_document_id(Text(winner[@"path"]))) [winner removeObjectForKey:@"originalPath"];
    return winner;
}

NSArray<NSDictionary*>* spdf_palette_merge_collection_copies(
    NSArray<NSDictionary*>* candidates, NSDictionary<NSString*, NSString*>* originalPathByDocumentID) {
    NSMutableDictionary<NSString*, NSString*>* documentByPath = [NSMutableDictionary dictionary];
    for (NSString* identifier in originalPathByDocumentID ?: @{})
        documentByPath[PathKey(Text(originalPathByDocumentID[identifier]))] = identifier;
    // A working copy's tab may already know where its original lives; that
    // folds the original in before the Collection has been read.
    for (NSDictionary* candidate in candidates ?: @[]) {
        NSString* copyOf = [candidate isKindOfClass:NSDictionary.class]
            ? spdf_palette_collection_copy_document_id(Text(candidate[@"path"])) : nil;
        NSString* original = copyOf ? Text(candidate[@"originalPath"]) : @"";
        if (original.length && !documentByPath[PathKey(original)]) documentByPath[PathKey(original)] = copyOf;
    }
    NSMutableArray<NSMutableDictionary*>* rows = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSNumber*>* rowForDocument = [NSMutableDictionary dictionary];
    for (NSDictionary* candidate in candidates ?: @[]) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary* row = [candidate mutableCopy];
        NSString* path = Text(row[@"path"]);
        NSString* copyOf = spdf_palette_collection_copy_document_id(path);
        NSString* known = Text(row[@"collectionHistoryID"]);
        NSString* document = copyOf ?: (known.length ? known : documentByPath[PathKey(path)]);
        if (copyOf && Text(originalPathByDocumentID[copyOf]).length)
            row[@"originalPath"] = originalPathByDocumentID[copyOf];
        NSNumber* existing = document.length ? rowForDocument[document] : nil;
        NSMutableDictionary* kept = existing ? rows[existing.unsignedIntegerValue] : nil;
        // Only a working copy folds into its document; a saved version shown
        // under its own label stays a row of its own.
        BOOL copyInvolved = copyOf || spdf_palette_collection_copy_document_id(Text(kept[@"path"]));
        BOOL labelled = Text(row[@"collectionVersionLabel"]).length || Text(kept[@"collectionVersionLabel"]).length;
        if (kept && copyInvolved && !labelled) {
            rows[existing.unsignedIntegerValue] = MergedRow(kept, row);
            continue;
        }
        if (document.length && !existing) rowForDocument[document] = @(rows.count);
        [rows addObject:row];
    }
    return rows;
}

NSDictionary<NSString*, NSString*>* spdf_palette_collection_original_paths(NSDictionary* manifest) {
    NSDictionary* documents = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"documents"] : nil;
    if (![documents isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary* paths = [NSMutableDictionary dictionaryWithCapacity:documents.count];
    for (NSString* identifier in documents) {
        NSDictionary* document = documents[identifier];
        if (![identifier isKindOfClass:NSString.class] || ![document isKindOfClass:NSDictionary.class]) continue;
        if (Text(document[@"path"]).length) paths[identifier] = document[@"path"];
    }
    return paths;
}

NSDictionary<NSString*, NSString*>* spdf_palette_collection_titles(NSDictionary* manifest) {
    NSDictionary* documents = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"documents"] : nil;
    if (![documents isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary* titles = [NSMutableDictionary dictionaryWithCapacity:documents.count];
    for (NSString* identifier in documents) {
        NSDictionary* document = documents[identifier];
        if (![identifier isKindOfClass:NSString.class] || ![document isKindOfClass:NSDictionary.class]) continue;
        NSString* title = spdf_palette_file_display_name(Collapsed(document[@"title"]));
        if (title.length) titles[identifier] = title;
    }
    return titles;
}

NSArray<NSDictionary*>* spdf_palette_titled_from_collection(NSArray<NSDictionary*>* rows,
    NSDictionary<NSString*, NSString*>* originalPathByDocumentID, NSDictionary<NSString*, NSString*>* titles) {
    if (!titles.count) return rows ?: @[];
    NSMutableDictionary<NSString*, NSString*>* documentByPath = [NSMutableDictionary dictionary];
    for (NSString* identifier in originalPathByDocumentID ?: @{})
        documentByPath[PathKey(Text(originalPathByDocumentID[identifier]))] = identifier;
    NSMutableArray* titled = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary* row in rows ?: @[]) {
        NSString* path = [row isKindOfClass:NSDictionary.class] ? Text(row[@"path"]) : @"";
        NSString* title = Text(row[@"title"]);
        // Only a row still named by its machine-made file name is renamed; a
        // saved version's label and a document's own title stay.
        if (!path.length || Text(row[@"collectionVersionLabel"]).length || !spdf_palette_name_is_opaque(title)) {
            if (row) [titled addObject:row];
            continue;
        }
        NSString* known = Text(row[@"collectionHistoryID"]);
        NSString* document = spdf_palette_collection_copy_document_id(path) ?:
            (known.length ? known : documentByPath[PathKey(path)]);
        NSString* stored = document.length ? titles[document] : nil;
        NSString* better = stored.length ? spdf_palette_document_title(path, nil, stored) : title;
        if ([better isEqualToString:title]) { [titled addObject:row]; continue; }
        NSMutableDictionary* renamed = [row mutableCopy];
        renamed[@"title"] = better;
        [titled addObject:renamed];
    }
    return titled;
}
