#pragma once

#import <Foundation/Foundation.h>
#import "markdown/SPDFTextDocumentFormats.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacMarkdownLinkKind) {
    SPDFMacMarkdownLinkRejected = 0,
    SPDFMacMarkdownLinkExternal,
    SPDFMacMarkdownLinkDocument,
    SPDFMacMarkdownLinkAnchor,
};

@interface SPDFMacMarkdownLinkResolution : NSObject
@property(nonatomic, readonly) SPDFMacMarkdownLinkKind kind;
@property(nonatomic, readonly, copy, nullable) NSURL* URL;
@property(nonatomic, readonly, copy, nullable) NSString* anchor;
@end

BOOL spdf_mac_path_is_markdown(NSString* _Nullable path);
BOOL spdf_mac_type_is_markdown(UTType* _Nullable type);
NSString* spdf_mac_markdown_heading_slug(NSString* heading);
SPDFMacMarkdownLinkResolution* spdf_mac_resolve_markdown_link(NSString* target,
                                                              NSURL* documentURL,
                                                              BOOL wikiLink);

NS_ASSUME_NONNULL_END
