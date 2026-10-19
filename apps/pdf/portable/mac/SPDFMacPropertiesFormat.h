#import <Foundation/Foundation.h>

// Pure value-formatting helpers for the document-properties panel. No AppKit,
// no document access — every function maps plain inputs to display strings (or
// NSDate), so they are unit-testable in isolation
// (see tests/SPDFMacPropertiesFormatTests.mm).

// Parses a PDF date string (D:YYYYMMDDHHmmSSOHH'mm', PDF 32000-1 §7.9.4).
// Everything after the 4-digit year is optional; the optional offset is
// Z / +HH'mm' / -HH'mm' (apostrophe variants tolerated). A missing offset means
// local time. Returns nil for garbage, partial fields (odd digit count),
// out-of-range components (month 13, Feb 30, hour 24, ...), or a malformed
// offset. Trailing junk after a valid date block is ignored.
NSDate* spdf_properties_parse_pdf_date(NSString* raw);

// "614 bytes", "2.4 MB (2,437,120 bytes)". 1000-based units (Finder
// convention); the exact grouped byte count is appended from 1 KB up.
NSString* spdf_properties_format_file_size(unsigned long long bytes);

// "210 × 297 mm · 8.27 × 11.69 in · 595 × 842 pt" from PDF points (1/72 in).
// Returns @"" when either dimension is not a positive finite number.
NSString* spdf_properties_format_page_size_pt(CGFloat widthPt, CGFloat heightPt);

// One-line security summary: "Not encrypted",
// "Encrypted — Standard V4 R4 128-bit AES", optionally followed by
// " · printing and copying not allowed" for denied permissions.
NSString* spdf_properties_security_summary(NSString* encryptionDetail,
                                           BOOL canPrint,
                                           BOOL canCopy,
                                           BOOL canEdit,
                                           BOOL canAnnotate);

// Unicode-aware word count plus non-whitespace character count for `text`,
// accumulated into *words / *chars (callers pass zero-initialized totals and
// may call once per page).
void spdf_properties_count_text(NSString* text, NSUInteger* words, NSUInteger* chars);
