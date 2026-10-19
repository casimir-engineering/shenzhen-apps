/* Fuzz target: miniupnpc's SSDP answer parsing (parseMSEARCHReply in minissdpc.c, static, so this file includes
 * the vendored source unchanged and is linked without its object). Any device on the LAN can answer an M-SEARCH.
 * The fields found are copied the way ssdpDiscoverDevices copies them into its device list. */

#include <minissdpc.c>

#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const char *location = NULL, *st = NULL, *usn = NULL;
    int locationSize = 0, stSize = 0, usnSize = 0;
    char *reply;
    if (size > 1536) return 0; /* the receive buffer ssdpDiscoverDevices reads into */
    reply = malloc(size + 1);
    if (reply == NULL) return 0;
    memcpy(reply, data, size);
    reply[size] = '\0';
    parseMSEARCHReply(reply, (int)size, &location, &locationSize, &st, &stSize, &usn, &usnSize);
    if (st != NULL && location != NULL) {
        struct UPNPDev *device = malloc(sizeof(struct UPNPDev) + locationSize + stSize + usnSize + 3);
        if (device != NULL) {
            device->pNext = NULL;
            device->descURL = device->buffer;
            device->st = device->buffer + 1 + locationSize;
            device->usn = device->st + 1 + stSize;
            memcpy(device->buffer, location, locationSize);
            device->buffer[locationSize] = '\0';
            memcpy(device->st, st, stSize);
            device->buffer[locationSize + 1 + stSize] = '\0';
            if (usn != NULL) memcpy(device->usn, usn, usnSize);
            device->buffer[locationSize + 1 + stSize + 1 + usnSize] = '\0';
            freeUPNPDevlist(device);
        }
    }
    free(reply);
    return 0;
}
