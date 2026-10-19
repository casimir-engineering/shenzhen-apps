// Friends messages in ShenzhenPDF's Cmd+K palette (brief § Interface: results include conversation, timestamp and
// matching context; opening one navigates to the highlighted message).
//
// The palette's rows are dictionaries with kind, title and subtitle (SPDFMacCollectionPalette.mm). Friends rows use
// kind "friendsMessage" and carry the conversation and message ids for opening. They sit after the documents and
// Collection results and before "Ask AI about this…", which stays the palette's last row.

#import <Foundation/Foundation.h>

@class SZFriendsSearchResult;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacFriendsPaletteKind;  // "friendsMessage"
FOUNDATION_EXPORT const NSUInteger SPDFMacFriendsPaletteLimit; // 5, like each Collection tier

// A "Friends messages" header, then rows with title "Mei · Yesterday" and subtitle "Mei: …the delivery date moved
// to…" (excerpt segments joined on one line). Empty when there are no results.
NSArray<NSDictionary*>* SPDFMacFriendsPaletteRows(NSArray<SZFriendsSearchResult*>* results);

// `rows` with `friendsRows` inserted before a trailing "askAI" row, or appended when there is none.
NSArray<NSDictionary*>* SPDFMacFriendsPaletteMergeRows(NSArray<NSDictionary*>* rows,
                                                      NSArray<NSDictionary*>* friendsRows);

BOOL SPDFMacFriendsPaletteRowIsFriends(NSDictionary* row);

NS_ASSUME_NONNULL_END
