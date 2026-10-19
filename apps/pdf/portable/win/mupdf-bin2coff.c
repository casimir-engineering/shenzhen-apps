/* mupdf-bin2coff -- embed a binary file into an ARM64 COFF object.
 *
 *   mupdf-bin2coff <input> <output.obj> <symbol>
 *
 * Emits one .rdata section containing
 *
 *     [ the file's bytes ][ pad to 8 ][ uint32 length ]
 *
 * and two external symbols: <symbol> at offset 0, and <symbol>_size at the
 * padded offset. That is the interface mupdf/scripts/hexdump.sh produces on
 * POSIX (`const unsigned char _binary_X[]`, `const unsigned int
 * _binary_X_size`), so MuPDF's own sources link against it unchanged.
 *
 * WHY NOT mupdf/scripts/bin2coff.c, WHICH DOES THE SAME JOB
 * ---------------------------------------------------------
 * Because its ARM64 output does not link. It places the size word immediately
 * after the data with no padding, so for any blob whose length is not a
 * multiple of 4 the size symbol lands at an unaligned offset, and AArch64's
 * LDR (immediate) cannot address it:
 *
 *   libmupdf.lib(hyphen.obj) : error LNK2048: relocation PAGEOFFSET_12L
 *   targeting '_binary_hyph_all_zip_size' is invalid for the instruction
 *   ... due to bad alignment of offset to target (C03); expected to be
 *   4 bytes aligned
 *
 * Roughly three quarters of MuPDF's 182 embedded blobs have a length that is
 * not a multiple of 4, so this is systemic rather than bad luck. Padding to 8
 * (not 4) also keeps the data itself 8-aligned for the next object the linker
 * places, and costs at most seven bytes per blob.
 *
 * WHY A TOOL AT ALL: MSVC cannot compile the hexdumped C form of these files.
 * It needs multiple GB of heap per megabyte of string literal and dies with
 * "fatal error C1060: compiler is out of heap space"; the largest blob here is
 * 103 MB of C. See portable/win/mupdf-gen-ninja.sh.
 *
 * Deliberately writes every field byte by byte rather than through packed
 * structs: COFF is little-endian and fully specified, struct packing is neither.
 *
 * Built for the guest by portable/win/mupdf-gen-ninja.sh's `host_exe` rule.
 * Owned by track T0.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IMAGE_FILE_MACHINE_ARM64        0xAA64
#define IMAGE_SCN_CNT_INITIALIZED_DATA  0x00000040u
#define IMAGE_SCN_ALIGN_16BYTES         0x00500000u
#define IMAGE_SCN_MEM_READ              0x40000000u
#define IMAGE_SYM_CLASS_EXTERNAL        2

#define FILE_HEADER_SIZE     20
#define SECTION_HEADER_SIZE  40
#define SYMBOL_SIZE          18
#define SIZE_SUFFIX          "_size"

static unsigned char* out;
static size_t out_len;

static void put8(size_t at, unsigned v)
{
    out[at] = (unsigned char)(v & 0xFFu);
}

static void put16(size_t at, unsigned v)
{
    out[at] = (unsigned char)(v & 0xFFu);
    out[at + 1] = (unsigned char)((v >> 8) & 0xFFu);
}

static void put32(size_t at, unsigned long v)
{
    out[at] = (unsigned char)(v & 0xFFu);
    out[at + 1] = (unsigned char)((v >> 8) & 0xFFu);
    out[at + 2] = (unsigned char)((v >> 16) & 0xFFu);
    out[at + 3] = (unsigned char)((v >> 24) & 0xFFu);
}

/* One symbol table entry. Both names here are longer than eight characters
 * (they all start with "_binary_"), so both go through the string table: an
 * 8-byte field of two zero longs, the second being the offset. */
static void put_symbol(size_t at, unsigned long name_offset, unsigned long value)
{
    put32(at, 0);
    put32(at + 4, name_offset);
    put32(at + 8, value);
    put16(at + 12, 1);              /* SectionNumber: 1-based, our only section */
    put16(at + 14, 0);              /* Type: not a function */
    put8(at + 16, IMAGE_SYM_CLASS_EXTERNAL);
    put8(at + 17, 0);               /* no auxiliary records */
}

int main(int argc, char** argv)
{
    const char *in_path, *out_path, *symbol;
    FILE* f;
    long file_len;
    size_t data_len, size_at, section_len;
    size_t sec_hdr, raw, symtab, strtab;
    size_t sym_len, sizesym_len, strtab_len;
    unsigned long name_off_data, name_off_size;

    if (argc != 4) {
        fprintf(stderr, "usage: mupdf-bin2coff <input> <output.obj> <symbol>\n");
        return 64;
    }
    in_path = argv[1];
    out_path = argv[2];
    symbol = argv[3];

    f = fopen(in_path, "rb");
    if (!f) {
        fprintf(stderr, "mupdf-bin2coff: cannot open %s\n", in_path);
        return 1;
    }
    if (fseek(f, 0, SEEK_END) != 0 || (file_len = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fprintf(stderr, "mupdf-bin2coff: cannot measure %s\n", in_path);
        fclose(f);
        return 1;
    }
    data_len = (size_t)file_len;

    /* Layout. size_at is data_len rounded up to 8 -- see the header comment for
     * why this padding is the entire reason this tool exists. */
    size_at = (data_len + 7u) & ~(size_t)7u;
    section_len = size_at + 4u;

    sym_len = strlen(symbol);
    sizesym_len = sym_len + strlen(SIZE_SUFFIX);
    /* String table: 4-byte total-size field, then each NUL-terminated name.
     * Offsets are counted from the start of that 4-byte field. */
    name_off_data = 4;
    name_off_size = (unsigned long)(4 + sym_len + 1);
    strtab_len = 4 + sym_len + 1 + sizesym_len + 1;

    sec_hdr = FILE_HEADER_SIZE;
    raw     = sec_hdr + SECTION_HEADER_SIZE;
    symtab  = raw + section_len;
    strtab  = symtab + 2 * SYMBOL_SIZE;
    out_len = strtab + strtab_len;

    out = (unsigned char*)calloc(out_len, 1);
    if (!out) {
        fprintf(stderr, "mupdf-bin2coff: out of memory for %lu bytes\n", (unsigned long)out_len);
        fclose(f);
        return 1;
    }

    if (data_len && fread(out + raw, 1, data_len, f) != data_len) {
        fprintf(stderr, "mupdf-bin2coff: short read on %s\n", in_path);
        fclose(f);
        free(out);
        return 1;
    }
    fclose(f);

    /* IMAGE_FILE_HEADER */
    put16(0, IMAGE_FILE_MACHINE_ARM64);
    put16(2, 1);                                   /* NumberOfSections */
    put32(4, 0);                                   /* TimeDateStamp: 0 keeps output reproducible */
    put32(8, (unsigned long)symtab);
    put32(12, 2);                                  /* NumberOfSymbols */
    put16(16, 0);                                  /* SizeOfOptionalHeader */
    put16(18, 0);                                  /* Characteristics */

    /* IMAGE_SECTION_HEADER */
    memcpy(out + sec_hdr, ".rdata", 6);
    put32(sec_hdr + 8, 0);                         /* VirtualSize (0 in an object) */
    put32(sec_hdr + 12, 0);                        /* VirtualAddress */
    put32(sec_hdr + 16, (unsigned long)section_len);
    put32(sec_hdr + 20, (unsigned long)raw);
    put32(sec_hdr + 24, 0);                        /* PointerToRelocations */
    put32(sec_hdr + 28, 0);                        /* PointerToLinenumbers */
    put16(sec_hdr + 32, 0);                        /* NumberOfRelocations */
    put16(sec_hdr + 34, 0);                        /* NumberOfLinenumbers */
    put32(sec_hdr + 36, IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ |
                        IMAGE_SCN_ALIGN_16BYTES);

    /* The length word the C side reads as `const unsigned int X_size`. */
    put32(raw + size_at, (unsigned long)data_len);

    put_symbol(symtab, name_off_data, 0);
    put_symbol(symtab + SYMBOL_SIZE, name_off_size, (unsigned long)size_at);

    put32(strtab, (unsigned long)strtab_len);
    memcpy(out + strtab + 4, symbol, sym_len);
    memcpy(out + strtab + 4 + sym_len + 1, symbol, sym_len);
    memcpy(out + strtab + 4 + sym_len + 1 + sym_len, SIZE_SUFFIX, strlen(SIZE_SUFFIX));

    f = fopen(out_path, "wb");
    if (!f) {
        fprintf(stderr, "mupdf-bin2coff: cannot create %s\n", out_path);
        free(out);
        return 1;
    }
    if (fwrite(out, 1, out_len, f) != out_len) {
        fprintf(stderr, "mupdf-bin2coff: short write on %s\n", out_path);
        fclose(f);
        free(out);
        return 1;
    }
    fclose(f);
    free(out);
    return 0;
}
