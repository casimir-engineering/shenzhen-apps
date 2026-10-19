#import <Foundation/Foundation.h>

#import "shenzhen_pdf_core.h"

static int gFailureCount = 0;

static void expect_han(NSString* label, const char* text, int expected) {
    int actual = spdf_text_contains_han(text);
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %d, got %d\n", label.UTF8String, expected, actual);
        ++gFailureCount;
    }
}

static void expect_latin(NSString* label, const char* text, int expected) {
    int actual = spdf_text_contains_latin(text);
    if (actual != expected) {
        fprintf(stderr, "FAIL latin %s: expected %d, got %d\n", label.UTF8String, expected, actual);
        ++gFailureCount;
    }
}

static void expect_script(NSString* label, const char* code, spdf_translation_script expected) {
    spdf_translation_script actual = spdf_translation_script_for_language(code);
    if (actual != expected) {
        fprintf(stderr, "FAIL script %s: expected %d, got %d\n", label.UTF8String, (int)expected, (int)actual);
        ++gFailureCount;
    }
}

static void expect_decision(NSString* label, const char* text, const char* source, const char* target, int expected) {
    int actual = spdf_translation_should_translate(text, spdf_translation_script_for_language(source),
                                                   spdf_translation_script_for_language(target));
    if (actual != expected) {
        fprintf(stderr, "FAIL decision %s: expected %d, got %d\n", label.UTF8String, expected, actual);
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        expect_han(@"NULL input", NULL, 0);
        expect_han(@"empty string", "", 0);

        expect_han(@"pure Latin", "Purely Latin caption that must be skipped", 0);
        expect_han(@"Latin with accents",
                   "Coordonn\xC3\xA9"
                   "es pr\xC3\xA9"
                   "cises \xC3\xA0 v\xC3\xA9"
                   "rifier",
                   0);
        expect_han(@"punctuation and digits only", "3.3V / 100mA (numbers & units only)", 0);
        expect_han(@"fullwidth punctuation only", "\xEF\xBC\x8C\xE3\x80\x82\xEF\xBC\x9A\xE3\x80\x81", 0);

        expect_han(@"pure Han simplified", "\xE7\xA1\xAC\xE4\xBB\xB6\xE8\xAE\xBE\xE8\xAE\xA1\xE6\x89\x8B\xE5\x86\x8C",
                   1);
        expect_han(@"pure Han traditional", "\xE7\xA1\xAC\xE9\xAB\x94\xE8\xA8\xAD\xE8\xA8\x88", 1);
        expect_han(@"mixed Han and Latin", "\xE7\x94\xB5\xE6\xBA\x90\xE7\xAE\xA1\xE7\x90\x86 Power Management", 1);
        expect_han(@"single Han among digits", "PCB:1\xC2\xB1"
                                               "0.1 \xE6\xBF\x80\xE5\x85\x89",
                   1);

        // Boundary code points of the detected ranges.
        expect_han(@"U+4E00 first unified ideograph", "\xE4\xB8\x80", 1);
        expect_han(@"U+9FFF last unified ideograph", "\xE9\xBF\xBF", 1);
        expect_han(@"U+3400 first Extension A", "\xE3\x90\x80", 1);
        expect_han(@"U+4DBF last Extension A", "\xE4\xB6\xBF", 1);
        expect_han(@"U+F900 compatibility ideograph", "\xEF\xA4\x80", 1);
        expect_han(@"U+20000 Extension B (4-byte UTF-8)", "\xF0\xA0\x80\x80", 1);

        // Neighbouring non-Han CJK scripts must not count as Chinese.
        expect_han(@"U+33FF just below Extension A", "\xE3\x8F\xBF", 0);
        expect_han(@"U+A000 just above unified ideographs", "\xEA\x80\x80", 0);
        expect_han(@"hiragana only", "\xE3\x81\xB2\xE3\x82\x89\xE3\x81\x8C\xE3\x81\xAA", 0);
        expect_han(@"katakana only", "\xE3\x82\xAB\xE3\x82\xBF\xE3\x82\xAB\xE3\x83\x8A", 0);
        expect_han(@"hangul only", "\xED\x95\x9C\xEA\xB5\xAD\xEC\x96\xB4", 0);
        expect_han(@"emoji only", "\xF0\x9F\x98\x80\xF0\x9F\x8E\x89", 0);

        // Malformed UTF-8 must be skipped without crashing or matching.
        expect_han(@"stray continuation byte", "\x80\x80 abc", 0);
        expect_han(@"truncated 3-byte sequence at end", "abc\xE7\xA1", 0);
        expect_han(@"truncated 4-byte sequence at end", "abc\xF0\xA0\x80", 0);
        expect_han(@"invalid lead byte 0xFF", "\xFF\xFE abc", 0);
        expect_han(@"Han after malformed bytes", "\x80\xE7\xA1\xAC", 1);
        expect_han(@"lone lead byte then Latin", "\xE7 hardware", 0);

        // Latin-letter detector.
        expect_latin(@"NULL input", NULL, 0);
        expect_latin(@"empty string", "", 0);
        expect_latin(@"pure ASCII Latin", "Power Management", 1);
        expect_latin(@"single letter among digits", "3.3V", 1);
        expect_latin(@"accented Latin", "Coordonn\xC3\xA9"
                                        "es pr\xC3\xA9"
                                        "cises",
                     1);
        expect_latin(@"Latin Extended-A (Polish)",
                     "\xC5\x81\xC3\xB3"
                     "d\xC5\xBA",
                     1);
        expect_latin(@"Latin Extended Additional (Vietnamese)", "Vi\xE1\xBB\x87t", 1);
        expect_latin(@"digits and punctuation only", "3.3 / 100 (,;:!)", 0);
        expect_latin(@"multiplication and division signs", "3\xC3\x97"
                                                           "4\xC3\xB7"
                                                           "2",
                     0);
        expect_latin(@"pure Han", "\xE7\xA1\xAC\xE4\xBB\xB6\xE8\xAE\xBE\xE8\xAE\xA1", 0);
        expect_latin(@"Cyrillic only", "\xD0\xA0\xD1\x83\xD1\x81\xD1\x81\xD0\xBA\xD0\xB8\xD0\xB9", 0);
        expect_latin(@"hiragana only", "\xE3\x81\xB2\xE3\x82\x89\xE3\x81\x8C\xE3\x81\xAA", 0);
        expect_latin(@"mixed Han and Latin", "\xE7\x94\xB5\xE6\xBA\x90 Power", 1);
        expect_latin(@"malformed bytes then Latin", "\x80\xFF abc", 1);

        // Language code -> script mapping.
        expect_script(@"zh", "zh", SPDF_TRANSLATION_SCRIPT_HAN);
        expect_script(@"zt traditional", "zt", SPDF_TRANSLATION_SCRIPT_HAN);
        expect_script(@"zh-TW region", "zh-TW", SPDF_TRANSLATION_SCRIPT_HAN);
        expect_script(@"ZH uppercase", "ZH", SPDF_TRANSLATION_SCRIPT_HAN);
        expect_script(@"en", "en", SPDF_TRANSLATION_SCRIPT_LATIN);
        expect_script(@"pt_BR underscore region", "pt_BR", SPDF_TRANSLATION_SCRIPT_LATIN);
        expect_script(@"vi", "vi", SPDF_TRANSLATION_SCRIPT_LATIN);
        expect_script(@"ru", "ru", SPDF_TRANSLATION_SCRIPT_OTHER);
        expect_script(@"ja", "ja", SPDF_TRANSLATION_SCRIPT_OTHER);
        expect_script(@"ko", "ko", SPDF_TRANSLATION_SCRIPT_OTHER);
        expect_script(@"NULL code", NULL, SPDF_TRANSLATION_SCRIPT_UNKNOWN);
        expect_script(@"empty code", "", SPDF_TRANSLATION_SCRIPT_UNKNOWN);
        expect_script(@"garbage code", "x1", SPDF_TRANSLATION_SCRIPT_UNKNOWN);
        expect_script(@"unrecognized code", "qq", SPDF_TRANSLATION_SCRIPT_UNKNOWN);

        // Per-item translate/skip decision.
        static const char* kHan = "\xE7\xA1\xAC\xE4\xBB\xB6\xE8\xAE\xBE\xE8\xAE\xA1";
        static const char* kLatin = "Hardware design manual";
        static const char* kMixed = "\xE7\x94\xB5\xE6\xBA\x90\xE7\xAE\xA1\xE7\x90\x86 Power Management";
        static const char* kNeither = "3.3 / 100 \xEF\xBC\x8C\xE3\x80\x82 \xC2\xB1 42";

        // Known Chinese source takes precedence (existing zh behavior must not regress).
        expect_decision(@"zh->en Han", kHan, "zh", "en", 1);
        expect_decision(@"zh->en Latin", kLatin, "zh", "en", 0);
        expect_decision(@"zh->en mixed", kMixed, "zh", "en", 1);
        expect_decision(@"zh->en digits/punct", kNeither, "zh", "en", 0);
        expect_decision(@"zt->en Han", kHan, "zt", "en", 1);
        // Precedence: an explicitly Chinese source keeps the Han filter even
        // when the target script would say otherwise.
        expect_decision(@"zh-TW->fr Latin skipped", kLatin, "zh-TW", "fr", 0);

        // Known Latin-script source: keep Latin items, skip Han and neutral items.
        expect_decision(@"en->zh Latin", kLatin, "en", "zh", 1);
        expect_decision(@"en->zh Han", kHan, "en", "zh", 0);
        expect_decision(@"en->zh mixed", kMixed, "en", "zh", 0);
        expect_decision(@"en->zh digits/punct", kNeither, "en", "zh", 0);
        expect_decision(@"fr->en Latin", kLatin, "fr", "en", 1);
        expect_decision(@"fr->en Han", kHan, "fr", "en", 0);

        // Unknown source falls back to the script-vs-target heuristic.
        expect_decision(@"?->zh Latin", kLatin, "qq", "zh", 1);
        expect_decision(@"?->zh Han", kHan, "qq", "zh", 0);
        expect_decision(@"?->zh mixed", kMixed, "qq", "zh", 0);
        expect_decision(@"?->zh digits/punct", kNeither, "qq", "zh", 0);
        expect_decision(@"?->en Han", kHan, "qq", "en", 1);
        expect_decision(@"?->en Latin", kLatin, "qq", "en", 0);
        expect_decision(@"?->en mixed", kMixed, "qq", "en", 1);
        expect_decision(@"?->en digits/punct", kNeither, "qq", "en", 0);
        // Unknown source and unclassifiable target: never filter.
        expect_decision(@"?->ja Latin", kLatin, "qq", "ja", 1);
        expect_decision(@"?->ja digits/punct kept", kNeither, "qq", "ja", 1);

        // Sources in scripts the detectors cannot classify are never filtered.
        expect_decision(@"ru->en Cyrillic",
                        "\xD0\xA0\xD1\x83\xD1\x81\xD1\x81\xD0\xBA\xD0\xB8\xD0\xB9 \xD1\x82\xD0\xB5\xD0\xBA\xD1\x81\xD1\x82",
                        "ru", "en", 1);
        expect_decision(@"ru->en Latin kept", kLatin, "ru", "en", 1);
        expect_decision(@"ja->en Han kept", kHan, "ja", "en", 1);

        // Empty text never translates.
        expect_decision(@"empty text", "", "zh", "en", 0);
        expect_decision(@"NULL text", NULL, "en", "zh", 0);
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFTranslationChineseFilterTests passed\n");
    return 0;
}
