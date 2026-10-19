#import "SPDFMacCollectionPipe.h"
#include <fcntl.h>
@implementation SPDFCollectionPipe {
    NSFileHandle* _reader;
    NSFileHandle* _writer;
    NSMutableData* _buffer;
    NSLock* _writeLock;
    BOOL _closed;
}
- (instancetype)initWithReader:(NSFileHandle*)reader writer:(NSFileHandle*)writer {
    if ((self=[super init])) { _reader=reader; _writer=writer; _buffer=[NSMutableData data]; _writeLock=[NSLock new];
        fcntl(writer.fileDescriptor,F_SETNOSIGPIPE,1); }
    return self;
}
- (void)start {
    __weak SPDFCollectionPipe* weakSelf=self;
    _reader.readabilityHandler=^(NSFileHandle* handle) {
        SPDFCollectionPipe* owner=weakSelf; if (!owner) return;
        NSData* data=nil;
        @try { data=handle.availableData; } @catch (NSException* exception) { (void)exception; }
        if (!data.length) { [owner close]; if (owner.closedHandler) owner.closedHandler(); return; }
        NSMutableArray* messages=[NSMutableArray array];
        @synchronized(owner->_buffer) {
            [owner->_buffer appendData:data];
            if (owner->_buffer.length>8*1024*1024) { [owner close]; return; }
            while (YES) {
                const void* newline=memchr(owner->_buffer.bytes,'\n',owner->_buffer.length);
                if (!newline) break;
                NSUInteger length=(const char*)newline-(const char*)owner->_buffer.bytes;
                NSData* line=[owner->_buffer subdataWithRange:NSMakeRange(0,length)];
                [owner->_buffer replaceBytesInRange:NSMakeRange(0,length+1) withBytes:NULL length:0];
                id value=[NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if ([value isKindOfClass:NSDictionary.class]) [messages addObject:value];
            }
        }
        for (NSDictionary* message in messages) if (owner.messageHandler) owner.messageHandler(message);
    };
}
- (BOOL)send:(NSDictionary*)message {
    NSData* data=[NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || data.length>8*1024*1024) return NO;
    NSMutableData* line=[data mutableCopy]; [line appendBytes:"\n" length:1];
    [_writeLock lock]; BOOL ok=NO;
    @try { if (!_closed) { [_writer writeData:line]; ok=YES; } }
    @catch (NSException* exception) { (void)exception; }
    [_writeLock unlock]; return ok;
}
- (void)close {
    [_writeLock lock];
    if (!_closed) {
        _closed=YES; _reader.readabilityHandler=nil;
        @try { [_reader closeFile]; [_writer closeFile]; } @catch (NSException* exception) { (void)exception; }
    }
    [_writeLock unlock];
}
- (void)dealloc { [self close]; }
@end
