#pragma once
#import <Foundation/Foundation.h>
NSDictionary* SPDFMacAIAnswerCardTool(void);
// Cards require an exact retrieved citation; do not silently change their evidence.
NSDictionary* SPDFMacAIValidatedAnswerCard(NSDictionary* arguments, NSDictionary* chat);
NSString* SPDFMacAIAnswerCardText(NSDictionary* card);
