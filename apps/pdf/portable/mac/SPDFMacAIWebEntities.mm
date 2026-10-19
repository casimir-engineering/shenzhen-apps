#import "SPDFMacAIWebEntities.h"

static NSDictionary<NSString*, NSNumber*>* Table(void) {
    static NSDictionary* table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary* names = [NSMutableDictionary dictionary];
        // HTML 4's Latin-1 entities name U+00A0...U+00FF in order, and its Greek ones U+0391...U+03C9.
        NSArray* latin = [@"nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg "
            "plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute "
            "Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve "
            "Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc "
            "atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute "
            "ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml"
            componentsSeparatedByString:@" "];
        for (NSUInteger index = 0; index < latin.count; index++) names[latin[index]] = @(0xA0 + index);
        NSArray* greek = [@"Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu Xi Omicron Pi Rho - "
            "Sigma Tau Upsilon Phi Chi Psi Omega" componentsSeparatedByString:@" "];
        for (NSUInteger index = 0; index < greek.count; index++) {
            if ([greek[index] isEqual:@"-"]) continue;
            names[greek[index]] = @(0x391 + index);
            names[[greek[index] lowercaseString]] = @(0x3B1 + index);
        }
        names[@"sigmaf"] = @0x3C2;
        NSString* others = @"amp 26 lt 3C gt 3E quot 22 apos 27 ensp 2002 emsp 2003 thinsp 2009 zwnj 200C zwj 200D "
            "lrm 200E rlm 200F ndash 2013 mdash 2014 lsquo 2018 rsquo 2019 sbquo 201A ldquo 201C rdquo 201D bdquo 201E "
            "dagger 2020 Dagger 2021 bull 2022 hellip 2026 permil 2030 prime 2032 Prime 2033 lsaquo 2039 rsaquo 203A "
            "oline 203E frasl 2044 euro 20AC trade 2122 larr 2190 uarr 2191 rarr 2192 darr 2193 harr 2194 lArr 21D0 "
            "rArr 21D2 hArr 21D4 minus 2212 le 2264 ge 2265 ne 2260 asymp 2248 infin 221E sum 2211 prod 220F "
            "radic 221A "
            "part 2202 nabla 2207 isin 2208 notin 2209 cap 2229 cup 222A int 222B there4 2234 sim 223C cong 2245 "
            "equiv 2261 sub 2282 sup 2283 sube 2286 supe 2287 oplus 2295 otimes 2297 perp 22A5 sdot 22C5 loz 25CA "
            "spades 2660 clubs 2663 hearts 2665 diams 2666 OElig 152 oelig 153 Scaron 160 scaron 161 Yuml 178 "
            "fnof 192 circ 2C6 tilde 2DC forall 2200 exist 2203 empty 2205 and 2227 or 2228 ang 2220 lowast 2217 "
            "prop 221D image 2111 weierp 2118 real 211C alefsym 2135 crarr 21B5 lceil 2308 rceil 2309 lfloor 230A "
            "rfloor 230B lang 27E8 rang 27E9 thetasym 3D1 upsih 3D2 piv 3D6";
        NSArray* pairs = [others componentsSeparatedByString:@" "];
        for (NSUInteger index = 0; index + 1 < pairs.count; index += 2)
            names[pairs[index]] = @(strtoul([pairs[index + 1] UTF8String], NULL, 16));
        table = names;
    });
    return table;
}

uint32_t SPDFMacAIWebNamedEntity(NSString* name) { return [Table()[name] unsignedIntValue]; }
