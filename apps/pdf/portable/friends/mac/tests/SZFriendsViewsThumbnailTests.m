// Shenzhen Friends views tests: file previews on transfer cards (PROTOCOL.md § Thumbnails). A card lays its preview
// out from the snapshot's width and height before the picture loads and keeps that shape once it has; a missing or
// unreadable preview shows the type's icon from file.type_identifier; and the views load only a PNG of the declared
// size in the helper's own thumbnails directory, nothing else.

#import "SZFriendsViewsTestSupport.h"

#import "mac/SZFriendsItemViewsInternal.h"

#include <sys/stat.h>
#include <unistd.h>

static BOOL SZFLoads(NSString *path, NSInteger width, NSInteger height) {
    CGImageRef image = SZFriendsCopyThumbnailImage(path, width, height);
    if (image) CGImageRelease(image);
    return image != NULL;
}

static void SZFTestWhatLoads(void) {
    NSString *directory = SZFTestThumbnailDirectory();
    NSString *good = [directory stringByAppendingPathComponent:@"c0ffee00c0ffee00c0ffee00c0ffee00.png"];
    SZFExpect(SZFTestWritePreviewPNG(good, 136, 192), @"a preview written");
    SZFExpect(SZFLoads(good, 136, 192), @"the helper's PNG at its declared size loads");
    SZFExpect(!SZFLoads(good, 192, 136) && !SZFLoads(good, 136, 191), @"another declared size does not");
    SZFExpect(!SZFLoads(good, 0, 192) && !SZFLoads(good, 136, 193), @"sizes outside 1 to 192 do not");
    SZFExpect(!SZFLoads([directory stringByAppendingPathComponent:@"missing.png"], 136, 192), @"a missing file");
    // Outside the thumbnails directory: the state directory itself, its parent, a way out through "..".
    NSString *state = directory.stringByDeletingLastPathComponent;
    NSString *outside = [state stringByAppendingPathComponent:@"outside.png"];
    SZFTestWritePreviewPNG(outside, 136, 192);
    SZFExpect(!SZFLoads(outside, 136, 192), @"a PNG elsewhere in the state directory is not loaded");
    NSString *escape = [[directory stringByAppendingPathComponent:@".."] stringByAppendingPathComponent:@"outside.png"];
    SZFExpect(!SZFLoads(escape, 136, 192), @"nor through ..");
    SZFExpect(!SZFLoads(@"thumbnails/c0ffee00c0ffee00c0ffee00c0ffee00.png", 136, 192), @"nor a relative path");
    // Not a PNG, a link, a pipe, a file far larger than any preview.
    NSString *jpeg = [directory stringByAppendingPathComponent:@"jpeg.png"];
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:good]];
    [[rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{}] writeToFile:jpeg atomically:YES];
    SZFExpect(!SZFLoads(jpeg, 136, 192), @"a JPEG named .png is not a PNG");
    NSString *link = [directory stringByAppendingPathComponent:@"link.png"];
    symlink(good.fileSystemRepresentation, link.fileSystemRepresentation);
    SZFExpect(!SZFLoads(link, 136, 192), @"a symbolic link is not followed");
    NSString *pipe = [directory stringByAppendingPathComponent:@"pipe.png"];
    mkfifo(pipe.fileSystemRepresentation, 0600);
    NSDate *start = [NSDate date];
    SZFExpect(!SZFLoads(pipe, 136, 192) && -start.timeIntervalSinceNow < 1, @"a pipe is refused without waiting");
    NSString *large = [directory stringByAppendingPathComponent:@"large.png"];
    NSMutableData *padded = [NSMutableData dataWithContentsOfFile:good];
    padded.length = 2 << 20;
    [padded writeToFile:large atomically:YES];
    SZFExpect(!SZFLoads(large, 136, 192), @"a file larger than any preview is not read");
    // The IHDR must be the snapshot's size exactly (PROTOCOL.md § Thumbnails): a header changed without its checksum
    // to claim that size, a doubled slash or "." on the way in, and a picture of another size all show the type icon.
    NSString *tampered = [directory stringByAppendingPathComponent:@"tampered.png"];
    NSString *small = [directory stringByAppendingPathComponent:@"small.png"];
    SZFTestWritePreviewPNG(small, 100, 192);
    NSMutableData *claim = [NSMutableData dataWithContentsOfFile:small];
    ((uint8_t *)claim.mutableBytes)[19] = 136; // IHDR width 100 -> 136, checksum left as it was
    [claim writeToFile:tampered atomically:YES];
    SZFExpect(SZFLoads(small, 100, 192) && !SZFLoads(small, 136, 192), @"a 100 px preview loads only as 100 px");
    SZFExpect(!SZFLoads(tampered, 136, 192), @"a header changed to claim the snapshot's size is refused");
    NSString *name = good.lastPathComponent;
    SZFExpect(!SZFLoads([[directory stringByAppendingString:@"//"] stringByAppendingString:name], 136, 192) &&
                  !SZFLoads([[directory stringByAppendingString:@"/./"] stringByAppendingString:name], 136, 192),
              @"only the plain spelling of a path directly in thumbnails/");
    for (NSString *made in @[ outside, jpeg, link, pipe, large, tampered, small ])
        unlink(made.fileSystemRepresentation);
}

static SZFriendsTransferItemView *SZFTransfer(SZFriendsConversationPage *page, NSString *itemID) {
    for (SZFriendsItemView *view in page.itemViews)
        if ([view.itemID isEqualToString:itemID] && [view isKindOfClass:SZFriendsTransferItemView.class])
            return (SZFriendsTransferItemView *)view;
    return nil;
}

static SZFriendsConversationPage *SZFPage(NSString *conversationID, NSDictionary *data, NSWindow **window) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsConversationPage *page = [[SZFriendsConversationPage alloc] initWithContext:context
                                                                          conversationID:conversationID
                                                                        highlightMessage:nil];
    *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page applySnapshot:data];
    [page layoutSubtreeIfNeeded];
    return page;
}

static void SZFTestCardsWithPreviews(void) {
    NSWindow *window = nil;
    NSDictionary *mei = SZFTestSnapshot(@"conversation-mei");
    // A fresh name, so no earlier test's picture is cached: the first layout happens before it loads.
    NSMutableDictionary *data = [mei mutableCopy];
    NSMutableArray *items = [data[@"items"] mutableCopy];
    NSUInteger drawing = NSNotFound, contract = NSNotFound;
    for (NSUInteger index = 0; index < items.count; index++) {
        NSString *path = items[index][@"thumbnail"][@"path"];
        if (![path isKindOfClass:NSString.class]) continue;
        if ([items[index][@"thumbnail"][@"width"] integerValue] == 192) drawing = index;
        else contract = index;
    }
    SZFExpect(drawing != NSNotFound && contract != NSNotFound, @"Mei's conversation has both previews");
    if (drawing == NSNotFound || contract == NSNotFound) return;
    NSString *fresh = [SZFTestThumbnailDirectory() stringByAppendingPathComponent:@"fresh00000000000000000000.png"];
    SZFTestWritePreviewPNG(fresh, 192, 136);
    NSMutableDictionary *item = [items[drawing] mutableCopy], *thumbnail = [item[@"thumbnail"] mutableCopy];
    thumbnail[@"path"] = fresh;
    item[@"thumbnail"] = thumbnail;
    items[drawing] = item;
    data[@"items"] = items;
    SZFriendsConversationPage *page = SZFPage(@"c_mei", data, &window);
    SZFriendsTransferItemView *card = SZFTransfer(page, items[drawing][@"item_id"]);
    SZFExpect(card.preview.state == SZFriendsPreviewLoading, @"laid out before the picture loads: %ld",
              (long)card.preview.state);
    SZFExpect(NSEqualSizes(card.preview.size, NSMakeSize(64, 45)), @"192 x 136 takes 64 x 45: %@",
              NSStringFromSize(card.preview.size));
    CGFloat before = [card heightForWidth:372];
    SZFExpect(SZFTestWaitForPreviews(page) && card.preview.state == SZFriendsPreviewShown && card.preview.image,
              @"the picture arrives");
    SZFExpect([card heightForWidth:372] == before, @"and the card keeps its shape: %.0f, %.0f", before,
              [card heightForWidth:372]);
    SZFriendsTransferItemView *local = SZFTransfer(page, items[contract][@"item_id"]);
    SZFExpect(local.preview.state == SZFriendsPreviewShown && NSEqualSizes(local.preview.size, NSMakeSize(64, 64)),
              @"a local preview of a page: %@", NSStringFromSize(local.preview.size));

    // Missing: no preview, the type's icon from its identifier, in the icon's narrower slot.
    thumbnail[@"path"] = [SZFTestThumbnailDirectory() stringByAppendingPathComponent:@"gone000000000000000000000.png"];
    item[@"thumbnail"] = thumbnail;
    items[drawing] = item;
    data[@"items"] = items;
    [page applySnapshot:data];
    SZFExpect(SZFTestWaitForPreviews(page) && card.preview.state == SZFriendsPreviewTypeIcon &&
                  card.preview.typeIcon && NSEqualSizes(card.preview.size, NSMakeSize(28, 34)),
              @"a missing preview shows the type's icon: %ld", (long)card.preview.state);
    [window.contentView layoutSubtreeIfNeeded];
    SZFExpect(NSWidth(card.preview.frame) == 28, @"and the card lays out again around it");
    [page pageDidDisappear];

    // No preview at all (Priya's queued contract): the icon at once; no identifier: the drawn page.
    page = SZFPage(@"c_priya", SZFTestSnapshot(@"conversation-priya-queued"), &window);
    SZFriendsTransferItemView *queued = nil;
    for (SZFriendsItemView *view in page.itemViews)
        if ([view isKindOfClass:SZFriendsTransferItemView.class]) queued = (SZFriendsTransferItemView *)view;
    SZFExpect(queued.preview.state == SZFriendsPreviewTypeIcon && queued.preview.typeIcon,
              @"a transfer without a preview shows its type's icon");
    [queued.preview applyFile:@{@"name" : @"notes.xyz", @"kind_label" : @"XYZ", @"type_identifier" : NSNull.null}
                    thumbnail:nil];
    SZFExpect(queued.preview.typeIcon == nil, @"without an identifier the drawn page and kind label stand in");
    [page pageDidDisappear];
}

void SZFTestFilePreviews(void) {
    SZFTestWhatLoads();
    SZFTestCardsWithPreviews();
}
