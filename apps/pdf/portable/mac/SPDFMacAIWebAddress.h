#pragma once
// Which web addresses the assistant's open_page may reach (portable/docs/plans/ai-agent-capabilities.md § 2): public
// internet hosts over https, nothing else. The URL comes from a model that may have read hostile text, so it must
// never become a request to this Mac, the person's router or printer, a company network or a cloud metadata service.
// Pure: nothing here resolves a name or touches the network. SPDFMacAIWebFetcher resolves names and checks every
// address it may connect to before each hop; the connector checks the exact address again before it connects.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Why a page was not opened. Every web error carries one of these in SPDFMacAIWebErrorDomain; the tool provider turns
// it into a refusal for the model and a status line for the person.
typedef NS_ENUM(NSInteger, SPDFMacAIWebError) {
    SPDFMacAIWebErrorInvalidAddress = 1, // not a URL a page can be opened from
    SPDFMacAIWebErrorNotHTTPS,           // http:, file:, ftp:, ... or a redirect to one
    SPDFMacAIWebErrorCredentials,        // user or password in the URL
    SPDFMacAIWebErrorLocalName,          // localhost, .local, .internal, .lan, a name without a dot, ...
    SPDFMacAIWebErrorPrivateAddress,     // loopback, private, link-local, CGNAT, multicast or reserved
    SPDFMacAIWebErrorNotFound,           // the name does not resolve
    SPDFMacAIWebErrorUnreachable,        // no connection, or the certificate does not match
    SPDFMacAIWebErrorTimedOut,
    SPDFMacAIWebErrorTooManyRedirects,
    SPDFMacAIWebErrorHTTPStatus,         // the site answered with an error status
    SPDFMacAIWebErrorUnsupportedContent, // an image, an archive, an unknown compression: not text to read
    SPDFMacAIWebErrorBadResponse,        // not a readable HTTP response
    SPDFMacAIWebErrorCancelled,
    SPDFMacAIWebErrorSignInRequired,     // 401, or a page that is only a sign-in form: reported, never worked around
    SPDFMacAIWebErrorTooLarge,           // a PDF over open_page's document limit
    SPDFMacAIWebErrorLockedDocument,     // a PDF that needs a password
    SPDFMacAIWebErrorBadDocument,        // a PDF the reader's engine cannot open
};
FOUNDATION_EXPORT NSString* const SPDFMacAIWebErrorDomain;
// The HTTP status of an SPDFMacAIWebErrorHTTPStatus error (a site's or OpenRouter's), in its userInfo.
FOUNDATION_EXPORT NSString* const SPDFMacAIWebHTTPStatusKey;
NSError* SPDFMacAIWebMakeError(SPDFMacAIWebError code, NSString* message);

typedef NS_ENUM(NSInteger, SPDFMacAIWebAddressKind) {
    SPDFMacAIWebAddressPublic = 0,
    SPDFMacAIWebAddressLoopback,  // 127/8, ::1
    SPDFMacAIWebAddressPrivate,   // 10/8, 172.16/12, 192.168/16, fc00::/7, fec0::/10
    SPDFMacAIWebAddressLinkLocal, // 169.254/16 (cloud metadata lives here), fe80::/10
    SPDFMacAIWebAddressShared,    // 100.64/10, carrier-grade NAT (and Tailscale-style overlays)
    SPDFMacAIWebAddressMulticast, // 224/4, ff00::/8
    SPDFMacAIWebAddressReserved,  // 0/8, documentation, 240/4 and broadcast, IPv6 outside global unicast, tunnels
};
SPDFMacAIWebAddressKind SPDFMacAIWebClassifyIPv4(const uint8_t address[_Nonnull 4]);
// IPv6 forms that carry an IPv4 address (mapped, NAT64 64:ff9b::/96, 6to4) are judged by that address.
SPDFMacAIWebAddressKind SPDFMacAIWebClassifyIPv6(const uint8_t address[_Nonnull 16]);
// Every IPv4 spelling the system resolver accepts as numeric (inet_aton): dotted quads, "127.1", "0x7f.0.0.1",
// octal "0177.0.0.1", one 32-bit number "2130706433". NO for anything else.
BOOL SPDFMacAIWebParseIPv4(NSString* text, uint8_t address[_Nonnull 4]);
// Numeric text, IPv4 in any of those spellings or IPv6 with or without brackets. NO when it is neither, or when it
// names a zone ("fe80::1%en0"); otherwise its kind and its canonical text (dotted quad, compressed IPv6).
BOOL SPDFMacAIWebParseAddress(NSString* text, SPDFMacAIWebAddressKind* _Nullable kind,
                              NSString* _Nullable* _Nullable canonical);
// nil when `address` (numeric text, as a resolver returns it) may be connected to; otherwise a refusal for the model.
NSString* _Nullable SPDFMacAIWebAddressRefusal(NSString* address);

// One https URL, checked and split into what a request needs.
@interface SPDFMacAIWebTarget : NSObject
@property(nonatomic, readonly) NSURL* URL;                    // normalized, fragment removed
@property(nonatomic, readonly, copy) NSString* host;          // lowercase ASCII without a trailing dot, or numeric
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic, readonly, copy) NSString* requestTarget; // path and query, printable ASCII
@property(nonatomic, readonly, copy) NSString* hostHeader;
@property(nonatomic, readonly, copy, nullable) NSString* literalAddress; // canonical, when the host is numeric
@end
// The target for `URL`, or nil and an error saying why no page may be opened from it: the scheme, credentials, port,
// host syntax, local names and numeric hosts are checked here; a name still has to resolve to public addresses.
SPDFMacAIWebTarget* _Nullable SPDFMacAIWebTargetForURL(NSURL* _Nullable URL, NSError** error);

NS_ASSUME_NONNULL_END
