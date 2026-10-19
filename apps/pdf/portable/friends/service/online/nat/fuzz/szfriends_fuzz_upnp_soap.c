/* Fuzz target: miniupnpc's SOAP answer parsing (ParseNameValue over minixml) and the lookups the commands make in
 * it, plus the port listing parser, on the XML body a LAN device answers a control request with. */

#include <portlistingparse.h>
#include <upnpreplyparse.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static const char *const names[] = {"NewExternalIPAddress", "errorCode", "NewExternalPort", "NewInternalClient",
                                        "NewPortMappingDescription", "NewReservedPort", "UniqueID", "NewProtocol"};
    struct NameValueParserData reply;
    struct PortMappingParserData listing;
    char *xml;
    size_t i;
    if (size > 65536) return 0;
    xml = malloc(size + 1);
    if (xml == NULL) return 0;
    memcpy(xml, data, size);
    xml[size] = '\0';
    ParseNameValue(xml, (int)size, &reply);
    for (i = 0; i < sizeof names / sizeof names[0]; i++) {
        const char *value = GetValueFromNameValueList(&reply, names[i]);
        if (value != NULL) (void)strlen(value);
    }
    ClearNameValueList(&reply);
    memset(&listing, 0, sizeof listing);
    ParsePortListing(xml, (int)size, &listing);
    FreePortListing(&listing);
    free(xml);
    return 0;
}
