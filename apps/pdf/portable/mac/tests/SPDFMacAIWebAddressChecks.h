// Which addresses open_page may reach: every spelling of a private address is refused, public ones pass.
#pragma once
#import "SPDFMacAIWebFakes.h"

static SPDFMacAIWebAddressKind WebKind(NSString* text, BOOL* parsed) {
    SPDFMacAIWebAddressKind kind = SPDFMacAIWebAddressPublic;
    *parsed = SPDFMacAIWebParseAddress(text, &kind, NULL);
    return kind;
}

static void CheckAddressKinds(void) {
    NSDictionary<NSString*, NSNumber*>* expected = @{
        // IPv4, including the spellings inet_aton accepts: decimal, octal, hex, short forms.
        @"127.0.0.1" : @(SPDFMacAIWebAddressLoopback), @"127.1" : @(SPDFMacAIWebAddressLoopback),
        @"2130706433" : @(SPDFMacAIWebAddressLoopback), @"017700000001" : @(SPDFMacAIWebAddressLoopback),
        @"0177.0.0.1" : @(SPDFMacAIWebAddressLoopback), @"0x7f.0.0.1" : @(SPDFMacAIWebAddressLoopback),
        @"0x7f000001" : @(SPDFMacAIWebAddressLoopback), @"0x7F.1" : @(SPDFMacAIWebAddressLoopback),
        @"10.1.2.3" : @(SPDFMacAIWebAddressPrivate), @"167772161" : @(SPDFMacAIWebAddressPrivate),
        @"012.0.0.1" : @(SPDFMacAIWebAddressPrivate), @"172.16.0.1" : @(SPDFMacAIWebAddressPrivate),
        @"172.31.255.255" : @(SPDFMacAIWebAddressPrivate), @"192.168.1.1" : @(SPDFMacAIWebAddressPrivate),
        @"3232235777" : @(SPDFMacAIWebAddressPrivate), @"169.254.169.254" : @(SPDFMacAIWebAddressLinkLocal),
        @"0xa9.0xfe.0xa9.0xfe" : @(SPDFMacAIWebAddressLinkLocal), @"100.64.0.1" : @(SPDFMacAIWebAddressShared),
        @"100.127.255.254" : @(SPDFMacAIWebAddressShared), @"224.0.0.251" : @(SPDFMacAIWebAddressMulticast),
        @"239.255.255.250" : @(SPDFMacAIWebAddressMulticast), @"0.0.0.0" : @(SPDFMacAIWebAddressReserved),
        @"0" : @(SPDFMacAIWebAddressReserved), @"255.255.255.255" : @(SPDFMacAIWebAddressReserved),
        @"240.0.0.1" : @(SPDFMacAIWebAddressReserved), @"192.0.2.10" : @(SPDFMacAIWebAddressReserved),
        @"198.51.100.1" : @(SPDFMacAIWebAddressReserved), @"203.0.113.9" : @(SPDFMacAIWebAddressReserved),
        @"192.0.0.8" : @(SPDFMacAIWebAddressReserved),
        @"93.184.216.34" : @(SPDFMacAIWebAddressPublic), @"1572395042" : @(SPDFMacAIWebAddressPublic),
        @"8.8.8.8" : @(SPDFMacAIWebAddressPublic), @"172.32.0.1" : @(SPDFMacAIWebAddressPublic),
        @"100.128.0.1" : @(SPDFMacAIWebAddressPublic), @"198.18.0.5" : @(SPDFMacAIWebAddressPublic),
        // IPv6, including forms that carry an IPv4 address.
        @"::1" : @(SPDFMacAIWebAddressLoopback), @"[::1]" : @(SPDFMacAIWebAddressLoopback),
        @"0:0:0:0:0:0:0:1" : @(SPDFMacAIWebAddressLoopback), @"::" : @(SPDFMacAIWebAddressReserved),
        @"::ffff:127.0.0.1" : @(SPDFMacAIWebAddressLoopback), @"::ffff:7f00:1" : @(SPDFMacAIWebAddressLoopback),
        @"0:0:0:0:0:ffff:192.168.0.1" : @(SPDFMacAIWebAddressPrivate),
        @"::ffff:169.254.169.254" : @(SPDFMacAIWebAddressLinkLocal), @"::127.0.0.1" : @(SPDFMacAIWebAddressReserved),
        @"64:ff9b::10.0.0.1" : @(SPDFMacAIWebAddressPrivate), @"64:ff9b::7f00:1" : @(SPDFMacAIWebAddressLoopback),
        @"64:ff9b:1::1" : @(SPDFMacAIWebAddressReserved), @"2002:c0a8:101::1" : @(SPDFMacAIWebAddressPrivate),
        @"2002:7f00:1::" : @(SPDFMacAIWebAddressLoopback), @"fe80::1" : @(SPDFMacAIWebAddressLinkLocal),
        @"febf::1" : @(SPDFMacAIWebAddressLinkLocal), @"fec0::1" : @(SPDFMacAIWebAddressPrivate),
        @"fd12:3456::1" : @(SPDFMacAIWebAddressPrivate), @"fc00::1" : @(SPDFMacAIWebAddressPrivate),
        @"ff02::1" : @(SPDFMacAIWebAddressMulticast), @"2001::1" : @(SPDFMacAIWebAddressReserved),
        @"2001:db8::1" : @(SPDFMacAIWebAddressReserved), @"3fff::1" : @(SPDFMacAIWebAddressReserved),
        @"100::1" : @(SPDFMacAIWebAddressReserved), @"5f00::1" : @(SPDFMacAIWebAddressReserved),
        @"2606:4700:4700::1111" : @(SPDFMacAIWebAddressPublic), @"2a00:1450:4001::200e" : @(SPDFMacAIWebAddressPublic),
        @"::ffff:8.8.8.8" : @(SPDFMacAIWebAddressPublic), @"64:ff9b::808:808" : @(SPDFMacAIWebAddressPublic),
        @"2002:808:808::1" : @(SPDFMacAIWebAddressPublic),
    };
    for (NSString* text in expected) {
        BOOL parsed = NO;
        SPDFMacAIWebAddressKind kind = WebKind(text, &parsed);
        if (!parsed || kind != (SPDFMacAIWebAddressKind)expected[text].integerValue)
            fprintf(stderr, "  %s: parsed %d kind %ld, expected %ld\n", text.UTF8String, parsed, (long)kind,
                    (long)expected[text].integerValue);
        CHECK(parsed && kind == (SPDFMacAIWebAddressKind)expected[text].integerValue,
              "every spelling of an address is classified by the address it names");
        CHECK((SPDFMacAIWebAddressRefusal(text) == nil) == (kind == SPDFMacAIWebAddressPublic),
              "only public addresses may be connected to");
    }
    for (NSString* text in @[@"fe80::1%en0", @"[fe80::1%25en0]", @"1.2.3.4.5", @"256.1.1.1", @"1.2.3.256", @"08.1.1.1",
                             @"0x", @"0x1g", @"1..2", @"1.2.", @"", @"4294967296", @"1.16777216", @"example.com"]) {
        BOOL parsed = YES;
        WebKind(text, &parsed);
        CHECK(!parsed, "malformed numbers and zone ids are not addresses");
        CHECK(SPDFMacAIWebAddressRefusal(text) != nil, "something that is not an address is never connected to");
    }
    NSString* canonical = nil;
    CHECK(SPDFMacAIWebParseAddress(@"0x5d.184.0330.34", NULL, &canonical) && [canonical isEqual:@"93.184.216.34"],
          "a numeric host is connected to by its canonical dotted quad");
    CHECK(SPDFMacAIWebParseAddress(@"[2606:4700:4700:0:0:0:0:1111]", NULL, &canonical) &&
          [canonical isEqual:@"2606:4700:4700::1111"], "IPv6 is canonicalized and loses its brackets");
}

static SPDFMacAIWebError WebTargetError(NSString* link) {
    NSError* error = nil;
    SPDFMacAIWebTarget* target = SPDFMacAIWebTargetForURL([NSURL URLWithString:link], &error);
    return target ? (SPDFMacAIWebError)0 : (SPDFMacAIWebError)error.code;
}

static void CheckTargets(void) {
    NSDictionary<NSString*, NSNumber*>* refused = @{
        @"http://example.com/" : @(SPDFMacAIWebErrorNotHTTPS), @"file:///etc/passwd" : @(SPDFMacAIWebErrorNotHTTPS),
        @"ftp://example.com/x" : @(SPDFMacAIWebErrorNotHTTPS), @"javascript:alert(1)" : @(SPDFMacAIWebErrorNotHTTPS),
        @"https://user:secret@example.com/" : @(SPDFMacAIWebErrorCredentials),
        @"https://user@example.com/" : @(SPDFMacAIWebErrorCredentials),
        @"https://localhost/" : @(SPDFMacAIWebErrorLocalName), @"https://LOCALHOST./" : @(SPDFMacAIWebErrorLocalName),
        @"https://api.localhost/" : @(SPDFMacAIWebErrorLocalName),
        @"https://printer.local/" : @(SPDFMacAIWebErrorLocalName),
        @"https://nas.lan/" : @(SPDFMacAIWebErrorLocalName), @"https://db.internal/" : @(SPDFMacAIWebErrorLocalName),
        @"https://router.home.arpa/" : @(SPDFMacAIWebErrorLocalName),
        @"https://router/" : @(SPDFMacAIWebErrorLocalName),
        @"https://1.0.0.127.in-addr.arpa/" : @(SPDFMacAIWebErrorLocalName),
        @"https://127.0.0.1/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://2130706433/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://0x7f.1/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://0177.0.0.1/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://017700000001/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://127.1:8443/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://[::1]/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://[::ffff:7f00:1]/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://[::ffff:127.0.0.1]/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://[fe80::1%25en0]/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://169.254.169.254/latest/meta-data/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://100.64.0.1/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://224.0.0.1/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://0.0.0.0/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://[ff02::1]/" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://192.168.0.1./" : @(SPDFMacAIWebErrorPrivateAddress),
        @"https://1.2.3.4.5/" : @(SPDFMacAIWebErrorInvalidAddress),
        @"https://example.123/" : @(SPDFMacAIWebErrorInvalidAddress),
        @"https://example.com:0/" : @(SPDFMacAIWebErrorInvalidAddress),
        @"https://example.com:70000/" : @(SPDFMacAIWebErrorInvalidAddress),
        @"https:///path" : @(SPDFMacAIWebErrorInvalidAddress),
    };
    for (NSString* link in refused) {
        SPDFMacAIWebError code = WebTargetError(link);
        if (code != (SPDFMacAIWebError)refused[link].integerValue)
            fprintf(stderr, "  %s: %ld, expected %ld\n", link.UTF8String, (long)code, (long)refused[link].integerValue);
        CHECK(code == (SPDFMacAIWebError)refused[link].integerValue, "each unsafe URL is refused for its own reason");
    }
    NSError* error = nil;
    SPDFMacAIWebTarget* target = SPDFMacAIWebTargetForURL(
        [NSURL URLWithString:@"HTTPS://Docs.Example.COM./guide/a%20b?x=1&y=%C3%BC#section"], &error);
    CHECK([target.host isEqual:@"docs.example.com"] && target.port == 443 && !target.literalAddress,
          "a name is lowercased and loses its trailing dot");
    CHECK([target.requestTarget isEqual:@"/guide/a%20b?x=1&y=%C3%BC"] &&
          [target.hostHeader isEqual:@"docs.example.com"],
          "the request target keeps the path and query and drops the fragment");
    CHECK([target.URL.absoluteString isEqual:@"https://docs.example.com/guide/a%20b?x=1&y=%C3%BC"],
          "the normalized URL is https with no fragment");
    target = SPDFMacAIWebTargetForURL([NSURL URLWithString:@"https://1572395042:8443"], &error);
    CHECK([target.literalAddress isEqual:@"93.184.216.34"] && [target.hostHeader isEqual:@"93.184.216.34:8443"] &&
          [target.requestTarget isEqual:@"/"], "a public numeric host is used in its canonical form");
    target = SPDFMacAIWebTargetForURL([NSURL URLWithString:@"https://[2606:4700:4700::1111]/dns"], &error);
    CHECK([target.literalAddress isEqual:@"2606:4700:4700::1111"] &&
          [target.hostHeader isEqual:@"[2606:4700:4700::1111]"],
          "a public IPv6 host keeps its brackets in the Host header");
    if (@available(macOS 13.0, *)) {
        target = SPDFMacAIWebTargetForURL([NSURL URLWithString:@"https://bücher.example.de/"], &error);
        CHECK([target.host isEqual:@"xn--bcher-kva.example.de"], "an international name is resolved in its ASCII form");
    }
}
