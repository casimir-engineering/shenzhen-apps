/* Fuzz target: miniupnpc's device description parsing (parserootdesc over minixml) and the URLs built from it
 * (GetUPNPUrls), what UPNP_GetIGDFromUrl does with the XML a LAN device serves. */

#include <miniupnpc.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    struct IGDdatas igd;
    struct UPNPUrls urls;
    char *xml;
    if (size > 65536) return 0;
    xml = malloc(size + 1);
    if (xml == NULL) return 0;
    memcpy(xml, data, size);
    xml[size] = '\0';
    memset(&igd, 0, sizeof igd);
    memset(&urls, 0, sizeof urls);
    parserootdesc(xml, (int)size, &igd);
    GetUPNPUrls(&urls, &igd, "http://192.168.1.1:5000/rootDesc.xml", 0);
    FreeUPNPUrls(&urls);
    GetUPNPUrls(&urls, &igd, "http://[fe80::1%25en0]:49152/desc.xml", 4);
    FreeUPNPUrls(&urls);
    free(xml);
    return 0;
}
