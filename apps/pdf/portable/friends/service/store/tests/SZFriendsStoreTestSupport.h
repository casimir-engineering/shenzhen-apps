// Shared helpers for the store suite: expectations, temporary state directories, fixtures, child processes.

#import <Foundation/Foundation.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFTFailures;
extern NSString *SZFTFixturesDirectory;

#define SZFTExpect(condition, ...)                                                                                   \
    do {                                                                                                             \
        if (!(condition)) {                                                                                          \
            SZFTFailures++;                                                                                          \
            fprintf(stderr, "%s:%d: expected %s: %s\n", __FILE__, __LINE__, #condition,                              \
                    [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);                                           \
        }                                                                                                            \
    } while (0)

// A fresh directory under the suite's temporary root (removed when the suite ends), never the real state directory.
NSString *SZFTTemporaryDirectory(NSString *label);
void SZFTRemoveTemporaryRoot(void);
// Whether this SQLite keeps the trigram index: FTS5 is innocuous (usable from triggers with trusted_schema=OFF) from
// 3.44 on, so macOS 15 and earlier scan instead (ADR 0003 § FTS probe).
static inline BOOL SZFTIndexExpected(void) { return sqlite3_libversion_number() >= 3044000; }
SZFriendsStore *SZFTOpenStore(NSString *directory);
SZFriendsStore *_Nullable SZFTOpenStoreWithOptions(NSString *directory, SZFriendsStoreOptions *_Nullable options,
                                                  NSError *_Nullable *_Nullable error);
NSData *SZFTBytes(uint8_t value, NSUInteger length);
// A friend with identity key SZFTBytes(keyByte, 32), interacting at `interaction` seconds since 1970.
SZFriendsPersonRecord *SZFTAddPerson(SZFriendsStore *store, NSString *conversationID, uint8_t keyByte,
                                     SZFriendsRelation relation, NSTimeInterval interaction);
SZFriendsItemRecord *SZFTMessage(NSString *conversationID, NSString *itemID, NSString *_Nullable text,
                                 NSTimeInterval sentAt,
                                 SZFriendsDirection direction);
// Runs SQL on the store's write connection and returns the first column of the first row.
id _Nullable SZFTScalar(SZFriendsStore *store, NSString *sql, NSArray *binds);
NSData *SZFTBlake2b(NSData *data);
NSData *SZFTRandomData(NSUInteger length);
BOOL SZFTFileContains(NSString *path, NSData *needle);
NSUInteger SZFTFileMode(NSString *path);

// Runs this executable again as `--child <mode> <directory> <fd>`, returning its pid and the read end of a pipe the
// child writes progress lines to.
pid_t SZFTSpawnChild(NSString *mode, NSString *directory, int *readFD);
// Reads lines until one equals `line`, for at most `timeout` seconds; collects every line read into `lines`.
BOOL SZFTWaitForLine(int fd, NSString *line, NSTimeInterval timeout, NSMutableArray<NSString *> *_Nullable lines);
void SZFTKillChild(pid_t pid);
// In a child: one line to the parent.
void SZFTTell(int fd, NSString *line);

void SZFTRunStoreTests(void);
void SZFTRunHistoryTests(void);
void SZFTRunSearchTests(void);
void SZFTRunOutboxTests(void);
void SZFTRunTransferCheckTests(void);
void SZFTRunTransferTests(void);
void SZFTRunReceiveTests(void);
void SZFTRunReceivedFolderTests(void);
void SZFTRunTransferSafetyTests(void);
void SZFTRunKeyTests(void);
void SZFTRunAddByIDTests(void);
void SZFTRunRequestTests(void);
void SZFTRunDeviceTests(void);
void SZFTRunSyncTests(void);
void SZFTRunLapseTests(void);
void SZFTRunMigrationTests(void);
void SZFTRunCrashTests(void);
void SZFTRunThumbnailTests(void);
void SZFTRunMentionSearchTests(void);
int SZFTRunChild(int argc, const char *_Nonnull argv[_Nonnull]);
int SZFTWriteV1Fixture(NSString *path);

NS_ASSUME_NONNULL_END
