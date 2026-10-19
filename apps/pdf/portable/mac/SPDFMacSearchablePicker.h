#pragma once
#import <Cocoa/Cocoa.h>
#import "SPDFMacGroupActionButton.h"
// A native, keyboard-operable searchable dropdown. Data is requested only when opened.
@interface SPDFMacSearchablePicker : SPDFGroupActionButton
@property(nonatomic,copy) NSArray<NSDictionary*>* choices;
@property(nonatomic,copy) NSString* selectedID;
@property(nonatomic,copy) NSString* emptyMessage;
@property(nonatomic,copy) NSString* itemName; // Plural UI label, defaults to models.
@property(nonatomic,copy) void (^opened)(void);
@property(nonatomic,copy) void (^selected)(NSString* identifier);
- (void)refreshChoices;
@end
