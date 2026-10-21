// shenzhenpdf://friends/link#<payload>: the URL a friend link's or download link's web page opens ShenzhenPDF with,
// checked before anything else sees it (portable/friends/PROTOCOL.md § Links, The app's URL).
//
// Foundation only. Every URL the system hands the app that is not exactly that shape, or whose payload is not exactly
// one of the two layouts, is refused here and never reaches the helper or the views; one that passes is still only a
// question for the helper, whose card the person has to press before anything happens.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacFriendsLinkRefusal) {
    SPDFMacFriendsLinkAccepted = 0,
    SPDFMacFriendsLinkNotOurs,     // another scheme: not a link for Friends at all (a file URL, say)
    SPDFMacFriendsLinkOversized,   // longer than 512 bytes
    SPDFMacFriendsLinkMalformed,   // our scheme, but not exactly //friends/link#<payload>, or a payload that is not
                                   // canonical base64url
    SPDFMacFriendsLinkWrongType,   // a payload that is neither a friend link (f.) nor a download link (d.), or whose
                                   // bytes do not have that kind's layout
};

// The longest URL accepted, in UTF-8 bytes.
extern const NSUInteger SPDFMacFriendsLinkMaxBytes;

// The payload ("f.…" or "d.…") of `url` when it is a link for `scheme` ("shenzhenpdf"), else nil and why.
NSString* _Nullable SPDFMacFriendsLinkPayload(NSURL* _Nullable url, NSString* scheme,
                                              SPDFMacFriendsLinkRefusal* _Nullable refusal);
// The same check on the URL's text, for tests and for callers that never had an NSURL.
NSString* _Nullable SPDFMacFriendsLinkPayloadFromString(NSString* _Nullable text, NSString* scheme,
                                                        SPDFMacFriendsLinkRefusal* _Nullable refusal);

// shenzhenpdf://friends/conversation/<conversation_id> and shenzhenpdf://friends: where a Friends notification's click
// opens the app (portable/friends/PROTOCOL.md § Notifications). The conversation's id for the first, @"" (the list)
// for the second, nil for anything else: another scheme, a query or fragment, a trailing slash after the id, or an id
// outside [A-Za-z0-9_-] or longer than 64 bytes. It only opens the dropdown on what the helper then shows.
NSString* _Nullable SPDFMacFriendsRouteFromString(NSString* _Nullable text, NSString* scheme);

// The URLs the system hands the app, sorted: documents (file URLs) into `paths`, for -application:openFiles: as before,
// and the payload of every link for `scheme` that passes into `payloads`, in order. Anything else is dropped.
void SPDFMacFriendsSortOpenedURLs(NSArray<NSURL*>* urls, NSString* scheme, NSMutableArray<NSString*>* paths,
                                  NSMutableArray<NSString*>* payloads);
// The same, with every Friends route that passes (SPDFMacFriendsRouteFromString) into `routes`, in order.
void SPDFMacFriendsSortOpenedURLsWithRoutes(NSArray<NSURL*>* urls, NSString* scheme, NSMutableArray<NSString*>* paths,
                                            NSMutableArray<NSString*>* payloads,
                                            NSMutableArray<NSString*>* _Nullable routes);

NS_ASSUME_NONNULL_END
