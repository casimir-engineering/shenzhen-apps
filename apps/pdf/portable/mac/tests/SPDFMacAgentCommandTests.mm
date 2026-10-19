#import "SPDFMacAgentCommand.h"
#import <Foundation/Foundation.h>
#include <assert.h>
static NSUInteger supportCalls;
NSString* spdf_mac_support_directory(void) { supportCalls++; return @"/tmp/reader-agent-test"; }
static NSDictionary* parse(id value) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    return SPDFMacValidateAgentCommand(data, nil);
}
int main(void) {
    @autoreleasepool {
        assert(parse(@{@"action":@"inspect", @"path":@"/tmp/test.md"}));
        assert(parse(@{@"action":@"open", @"path":@"/tmp/test.pdf", @"page":@2, @"query":@"some text", @"context":@"nearby"}));
        assert(parse(@{@"action":@"inspect", @"path":@"/tmp/test.md", @"paper":@{@"paper-size":@"Letter"}}));
        assert(!parse(@{@"action":@"open", @"path":@"relative.md"}));
        assert(!parse(@{@"action":@"open", @"path":@"/tmp/command.spdf-command"}));
        assert(!parse(@{@"action":@"open", @"path":@"/tmp/a.md", @"page":@YES}));
        assert(!parse(@{@"action":@"open", @"path":@"/tmp/a.md", @"page":@1.5}));
        assert(!parse(@{@"action":@"open", @"path":@"/tmp/a.md", @"occurrence":@1}));
        assert(!parse(@{@"action":@"open", @"path":@"/tmp/a.md", @"paper":@{}}));
        assert(!parse(@{@"action":@"inspect", @"path":@"/tmp/a.md", @"query":@"text"}));
        assert(!parse(@{@"action":@"inspect", @"path":@"/tmp/a.md", @"paper":@{@"evil":@"x"}}));
        assert(!parse(@{@"action":@"inspect", @"path":@"/tmp/a.md", @"paper":@{@"paper-size":@1}}));
        assert(!parse(@{@"action":@"inspect", @"path":@"/tmp/a.md", @"renderDirectory":@"relative"}));
        assert(!parse(@[@1]));
        assert(!SPDFMacValidateAgentCommand([NSMutableData dataWithLength:65537], nil));
        assert(!SPDFMacValidateAgentCommand([@"not json" dataUsingEncoding:NSUTF8StringEncoding], nil));
        assert(parse(@{@"action":@"list-groups"}));
        assert(parse(@{@"action":@"jump-group",@"groupID":@"general"}));
        assert(parse(@{@"action":@"update-group",@"groupID":@"general",@"hidden":@YES}));
        assert(!parse(@{@"action":@"update-group",@"groupID":@"general",@"hidden":@1}));
        assert(parse(@{@"action":@"create-group",@"paths":@[@"/a.md",@"/b.pdf"],@"name":@"Research"}));
        assert(parse(@{@"action":@"update-group",@"groupID":@"general",@"collapsed":@NO}));
        assert(parse(@{@"action":@"move-tab",@"groupID":@"general",@"path":@"/a.md",@"beforePath":@"/b.pdf"}));
        assert(parse(@{@"action":@"move-group",@"groupID":@"id",@"beforeGroupID":@"general"}));
        assert(parse(@{@"action":@"ungroup",@"groupID":@"id",@"windowSessionID":@"window"}));
        assert(!parse(@{@"action":@"create-group",@"paths":@[]}));
        assert(!parse(@{@"action":@"create-group",@"paths":@[@"/a.md",@"/x/../a.md"]}));
        assert(!parse(@{@"action":@"create-group",@"paths":@[@"/a.md",@1]}));
        assert(!parse(@{@"action":@"update-group",@"groupID":@"id"}));
        assert(!parse(@{@"action":@"update-group",@"groupID":@"id",@"collapsed":@1}));
        assert(!parse(@{@"action":@"list-groups",@"path":@"/a.md"}));
        assert(!parse(@{@"action":@"move-tab",@"groupID":@"general"}));
        assert(!parse(@{@"action":@"ungroup",@"groupID":@""}));
        assert(!parse(@{@"action":@1}));
        NSArray* matches = @[@{@"page":@1, @"context":@"alpha quote"},
                             @{@"page":@2, @"context":@"beta quote"},
                             @{@"page":@2, @"context":@"alpha quote"}];
        assert(SPDFMacAgentChooseMatch(matches, @{}, nil) == 0);
        assert(SPDFMacAgentChooseMatch(matches, @{@"page":@2}, nil) == 1);
        assert(SPDFMacAgentChooseMatch(matches, @{@"page":@2, @"occurrence":@2}, nil) == 2);
        assert(SPDFMacAgentChooseMatch(matches, @{@"context":@"BETA"}, nil) == 1);
        assert(SPDFMacAgentChooseMatch(matches, @{@"context":@"alpha"}, nil) == -1);
        assert(SPDFMacAgentChooseMatch(matches, @{@"page":@2, @"context":@"alpha"}, nil) == 2);
        assert(SPDFMacAgentChooseMatch(matches, @{@"occurrence":@4}, nil) == -1);
        assert(SPDFMacAgentChooseMatch(@[], @{}, nil) == -1);
        // Validation and passage selection cannot initialize state directories.
        assert(supportCalls == 0);
        assert([SPDFMacAgentRequestDirectory() isEqual:@"/tmp/reader-agent-test/AgentRequests"]);
        assert(supportCalls == 1);
        puts("SPDFMacAgentCommandTests passed");
    }
}
