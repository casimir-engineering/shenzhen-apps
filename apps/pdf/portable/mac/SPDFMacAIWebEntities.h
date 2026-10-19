#pragma once
// HTML's named character references for the page reader (SPDFMacAIWebText.h): all of HTML 4's, which cover what
// pages write by name in practice. A name outside the table stays literal text, as a browser shows a typo.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The code point `name` (without '&' and ';') names, or 0.
uint32_t SPDFMacAIWebNamedEntity(NSString* name);

NS_ASSUME_NONNULL_END
