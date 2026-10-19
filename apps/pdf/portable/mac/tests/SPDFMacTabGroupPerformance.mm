#import <Cocoa/Cocoa.h>
#import "SPDFMacTabGroups.h"

// Standalone model benchmark: no NSApplication, window, filesystem or document load.
static NSUInteger groupReads;
@interface PerformanceTab : NSObject
@property(nonatomic, strong) SPDFTabGroup* storedGroup;
@property(nonatomic, copy) NSString* path;
- (SPDFTabGroup*)group;
- (void)setGroup:(SPDFTabGroup*)group;
@end
@implementation PerformanceTab
- (SPDFTabGroup*)group { ++groupReads; return _storedGroup; }
- (void)setGroup:(SPDFTabGroup*)group { _storedGroup=group; }
@end
static NSMutableArray* Fixture(NSUInteger count, NSUInteger perGroup) {
    NSMutableArray* tabs=[NSMutableArray array]; SPDFTabGroup* group=nil;
    for (NSUInteger i=0;i<count;i++) {
        if (perGroup && i%perGroup==0) group=[SPDFTabGroup groupWithColor:@"Blue"];
        PerformanceTab* tab=[PerformanceTab new]; tab.group=group;
        tab.path=[NSString stringWithFormat:@"/bench-%lu.pdf",(unsigned long)i]; [tabs addObject:tab];
    }
    return tabs;
}
int main(int argc, const char* argv[]) {
    BOOL verify=argc>1 && strcmp(argv[1],"--verify")==0;
    @autoreleasepool {
        for (NSNumber* countValue in @[@20,@200,@1000]) {
            NSUInteger count=countValue.unsignedIntegerValue;
            for (NSNumber* perValue in @[@0,@10,@1]) {
                NSUInteger per=perValue.unsignedIntegerValue;
                NSMutableArray* tabs=Fixture(count,per);
                spdf_tab_groups_normalize(tabs); groupReads=0;
                spdf_tab_groups_normalize(tabs); NSUInteger reads=groupReads;
                if (verify && reads>count*6+8) { fprintf(stderr,"nonlinear normalization: %lu reads for %lu tabs\n",(unsigned long)reads,(unsigned long)count); return 1; }
                const NSUInteger repeats=1000;
                CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
                for (NSUInteger i=0;i<repeats;i++) { @autoreleasepool { spdf_tab_groups_normalize(tabs); } }
                printf("tabs=%lu members/group=%lu normalize_us=%.3f property_reads=%lu\n",(unsigned long)count,(unsigned long)per,
                    (CFAbsoluteTimeGetCurrent()-start)*1e6/repeats,(unsigned long)reads);
            }
        }
    }
    return 0;
}
