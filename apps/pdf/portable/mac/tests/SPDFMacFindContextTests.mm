#import "SPDFMacFindContext.h"
#import "SPDFSearchSnippet.h"
#include <assert.h>
#include <stdio.h>

static NSString* Hit(NSDictionary* snippet) {
    NSArray* ranges=snippet[@"matchRanges"]; assert(ranges.count);
    return [snippet[@"title"] substringWithRange:[ranges.firstObject rangeValue]];
}
int main(void) {
    @autoreleasepool {
        // Adjacent list lines have overlapping expanded hit boxes: the old
        // first-intersection logic returned /docs instead of the image hit.
        spdf_text_line lines[]={
            {(char*)"2. /docs",{10,20,90,34},12},
            {(char*)"3. /images",{10,34,100,48},12},
            {(char*)"4. /portable",{10,48,110,62},12},
            {(char*)"Another image example",{10,100,220,114},12}};
        spdf_text_lines page={lines,4,0};
        SPDFMacFindContext* contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"ima" regex:NO multiline:NO];
        NSDictionary* snippet=[contexts contextForMatchRect:NSMakeRect(30,34,22,12)];
        assert([Hit(snippet) isEqual:@"ima"]);
        NSRange marked=[snippet[@"matchRanges"][0] rangeValue];
        assert([[snippet[@"title"] substringFromIndex:marked.location] hasPrefix:@"images"]);
        snippet=[contexts contextForMatchRect:NSMakeRect(70,101,25,12)];
        marked=[snippet[@"matchRanges"][0] rangeValue];
        assert([[snippet[@"title"] substringFromIndex:marked.location] hasPrefix:@"image example"]);
        contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"im[a-z]+" regex:YES multiline:NO];
        assert([Hit([contexts contextForMatchRect:NSMakeRect(30,34,22,12)]) isEqual:@"images"]);
        spdf_text_line wrapped[]={ {(char*)"A power",{0,0,50,14},12}, {(char*)"supply circuit",{0,14,90,28},12} };
        page=(spdf_text_lines){wrapped,2,0};
        contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"power supply" regex:NO multiline:NO];
        assert([Hit([contexts contextForMatchRect:NSMakeRect(10,1,70,27)]) isEqual:@"power supply"]);
        contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"power\\s+supply" regex:YES multiline:YES];
        assert([Hit([contexts contextForMatchRect:NSMakeRect(10,1,70,27)]) isEqual:@"power supply"]);
        contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"^supply" regex:YES multiline:NO];
        assert([Hit([contexts contextForMatchRect:NSMakeRect(0,14,40,14)]) isEqual:@"supply"]);
        spdf_text_line spaces[]={ {(char*)"power  supply",{0,0,100,14},12},
            {(char*)"power\tsupply",{0,20,100,34},12}, {(char*)"power\xc2\xa0supply",{0,40,100,54},12} };
        page=(spdf_text_lines){spaces,3,0};
        contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"power supply" regex:NO multiline:NO];
        for(int y=0;y<=40;y+=20) assert([Hit([contexts contextForMatchRect:NSMakeRect(0,y,100,14)]) isEqual:@"power supply"]);
        spdf_text_line repeated[]={ {(char*)"foo one bar",{0,0,100,14},12}, {(char*)"foo two bar",{0,30,100,44},12} };
        page=(spdf_text_lines){repeated,2,0};
        contexts=[[SPDFMacFindContext alloc] initWithLines:&page query:@"foo.*bar" regex:YES multiline:YES];
        assert([Hit([contexts contextForMatchRect:NSMakeRect(0,0,100,14)]) isEqual:@"foo one bar"]);
        assert([Hit([contexts contextForMatchRect:NSMakeRect(0,30,100,14)]) isEqual:@"foo two bar"]);
        NSString* source=@"🧭 Breadcrumbs\r\n\t\t2. /docs\u2028\t3. /images\n4. /portable";
        NSRange range=[source rangeOfString:@"images"];
        snippet=SPDFSearchSnippet(source,range,24,72);
        assert([Hit(snippet) isEqual:@"images"]);
        assert([snippet[@"title"] rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location==NSNotFound);
        assert(![snippet[@"title"] containsString:@"\t"]);
        NSString* decomposed=@"prefix cafe\u0301 and useful suffix";
        NSArray* matches=SPDFSearchTextRanges(decomposed,@"café",NO,NO);
        assert(matches.count==1);
        assert([Hit(SPDFSearchSnippet(decomposed,[matches[0] rangeValue],6,6)) isEqual:@"cafe\u0301"]);
        assert([SPDFSearchSnippet(source,NSMakeRange(NSNotFound,5),10,10)[@"matchRanges"] count]==0);
        puts("SPDFMacFindContextTests passed");
    }
    return 0;
}
