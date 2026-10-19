// Fuzz target: the STUN codec (SZFriendsNATStun.h), which reads datagrams from anyone who can reach the classifier's,
// the prober's or the TCP path's sockets before anything is authenticated. A parsed message is checked for integrity
// under a fixed key and written back as an answer, so the writer sees every address the parser accepts.

#import "service/online/nat/SZFriendsNATStun.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static const uint8_t key[] = "VOkJxbRl1RmTxUk/WvJxBt";
    SZFriendsStunMessage message;
    (void)SZFriendsStunFramedLength(data, size);
    if (!SZFriendsStunParse(data, size, &message)) return 0;
    (void)SZFriendsStunCheckIntegrity(data, size, &message, key, sizeof key - 1);
    if (message.username != NULL && message.usernameLength > 0) {
        volatile uint8_t first = message.username[0], last = message.username[message.usernameLength - 1];
        (void)first, (void)last;
    }
    if (message.hasMappedAddress) {
        uint8_t answer[SZFriendsStunMessageMax];
        (void)SZFriendsStunWriteBindingSuccess(answer, sizeof answer, message.transaction,
                                               (const struct sockaddr *)&message.mappedAddress, key, sizeof key - 1);
    }
    return 0;
}
