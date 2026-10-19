/* What rtc.h's structures look like to the C compiler of this target, for src/layout.rs to compare with the
 * hand-written declarations in src/ffi.rs, and the version the header names. Compiled by build.rs with the same
 * defines a consumer of rtc.h uses. */

#include <rtc/rtc.h>

#include <stddef.h>

#define SZFDC_LAYOUT_COUNT 18

size_t szfdc_layout(size_t *out, size_t count);
const char *szfdc_rtc_version(void);

size_t szfdc_layout(size_t *out, size_t count) {
    const size_t values[SZFDC_LAYOUT_COUNT] = {
        sizeof(rtcConfiguration),
        offsetof(rtcConfiguration, iceServersCount),
        offsetof(rtcConfiguration, proxyServer),
        offsetof(rtcConfiguration, bindAddress),
        offsetof(rtcConfiguration, certificateType),
        offsetof(rtcConfiguration, iceTransportPolicy),
        offsetof(rtcConfiguration, enableIceTcp),
        offsetof(rtcConfiguration, forceMediaTransport),
        offsetof(rtcConfiguration, portRangeBegin),
        offsetof(rtcConfiguration, portRangeEnd),
        offsetof(rtcConfiguration, mtu),
        offsetof(rtcConfiguration, maxMessageSize),
        sizeof(rtcReliability),
        offsetof(rtcReliability, maxRetransmits),
        sizeof(rtcDataChannelInit),
        offsetof(rtcDataChannelInit, protocol),
        offsetof(rtcDataChannelInit, negotiated),
        offsetof(rtcDataChannelInit, stream),
    };
    size_t i;
    for (i = 0; i < count && i < SZFDC_LAYOUT_COUNT; i++) out[i] = values[i];
    return SZFDC_LAYOUT_COUNT;
}

const char *szfdc_rtc_version(void) { return RTC_VERSION; }
