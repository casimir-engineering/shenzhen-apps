#pragma once
#import <Foundation/Foundation.h>

// Mixed selections receive one explicit action, rather than silently inverting
// each document's state under an ambiguous Keep / Unkeep menu label.
static inline BOOL SPDFCollectionSelectionIsKept(NSArray<NSDictionary*>* rows) {
    BOOL found = NO;
    for (NSDictionary* row in rows) {
        NSDictionary* version = row[@"version"];
        if (!version[@"id"]) continue;
        found = YES;
        if (![version[@"keep"] boolValue]) return NO;
    }
    return found;
}
