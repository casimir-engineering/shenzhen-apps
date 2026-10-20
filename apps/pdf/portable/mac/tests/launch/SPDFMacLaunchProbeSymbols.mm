// The launch probe's names for the main thread's samples (SPDFMacLaunchPerformanceProbe.mm, PROBE_SAMPLE).
//
// The reader is linked with -Wl,-x, so its Objective-C methods and static functions have no symbols left, and dladdr
// would name the nearest exported function before them. Inside the reader's image an address is named by the function
// that contains it, from the image's own list of function starts (LC_FUNCTION_STARTS): an exported symbol, an
// Objective-C method the runtime lists (those this probe replaced, by the originals it kept), or "?" for a stripped
// static function.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>
#include <algorithm>
#include <string>
#include <utility>
#include <vector>

static std::vector<std::pair<uintptr_t, std::string>> gMethods;
static std::vector<uintptr_t> gFunctionStarts;
static uintptr_t gReaderBase, gReaderEnd;
static void ListFunctionStarts(const struct mach_header_64* header, intptr_t slide) {
    const struct linkedit_data_command* starts = NULL;
    const struct segment_command_64 *text = NULL, *linkedit = NULL;
    const uint8_t* cursor = (const uint8_t*)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, cursor += ((const struct load_command*)cursor)->cmdsize) {
        const struct load_command* command = (const struct load_command*)cursor;
        if (command->cmd == LC_FUNCTION_STARTS) starts = (const struct linkedit_data_command*)command;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* segment = (const struct segment_command_64*)command;
            if (!strcmp(segment->segname, "__TEXT")) text = segment;
            if (!strcmp(segment->segname, "__LINKEDIT")) linkedit = segment;
        }
    }
    if (!starts || !text || !linkedit) return;
    gReaderBase = (uintptr_t)slide + text->vmaddr;
    gReaderEnd = gReaderBase + text->vmsize;
    const uint8_t* data = (const uint8_t*)((uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff + starts->dataoff);
    const uint8_t* end = data + starts->datasize;
    uintptr_t address = gReaderBase;
    while (data < end) {
        uint64_t delta = 0;
        int shift = 0;
        while (data < end) {
            uint8_t byte = *data++;
            delta |= (uint64_t)(byte & 0x7f) << shift;
            shift += 7;
            if (!(byte & 0x80)) break;
        }
        if (!delta) break;
        address += delta;
        gFunctionStarts.push_back(address);
    }
}
void SPDFLaunchProbeListReaderMethods(uintptr_t didFinishLaunching, uintptr_t friendsAfterFirstPaint) {
    Class reader = NSClassFromString(@"ShenzhenMacDelegate");
    const char* image = reader ? class_getImageName(reader) : NULL;
    Dl_info probe;
    dladdr((const void*)&SPDFLaunchProbeListReaderMethods, &probe);
    unsigned int count = 0;
    const char** names = image ? objc_copyClassNamesForImage(image, &count) : NULL;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        for (int meta = 0; meta < 2 && cls; meta++) {
            Class owner = meta ? object_getClass(cls) : cls;
            unsigned int methodCount = 0;
            Method* methods = class_copyMethodList(owner, &methodCount);
            for (unsigned int m = 0; m < methodCount; m++) {
                Dl_info where;
                IMP imp = method_getImplementation(methods[m]);
                if (dladdr((const void*)imp, &where) && where.dli_fbase == probe.dli_fbase) continue;
                gMethods.push_back({(uintptr_t)imp, std::string(meta ? "+[" : "-[") + names[i] + " " +
                                                        sel_getName(method_getName(methods[m])) + "]"});
            }
            free(methods);
        }
    }
    free(names);
    if (didFinishLaunching)
        gMethods.push_back({didFinishLaunching, "-[ShenzhenMacDelegate applicationDidFinishLaunching:]"});
    if (friendsAfterFirstPaint)
        gMethods.push_back({friendsAfterFirstPaint, "-[ShenzhenMacDelegate friendsAfterFirstPaint]"});
    std::sort(gMethods.begin(), gMethods.end());
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (image && !strcmp(_dyld_get_image_name(i), image)) {
            ListFunctionStarts((const struct mach_header_64*)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
            break;
        }
}
std::string SPDFLaunchProbeSymbol(uintptr_t pc) {
    Dl_info info;
    uintptr_t at = pc - 1;
    bool named = dladdr((void*)at, &info) && info.dli_sname;
    if (at < gReaderBase || at >= gReaderEnd || gFunctionStarts.empty()) return named ? info.dli_sname : "?";
    auto after = std::upper_bound(gFunctionStarts.begin(), gFunctionStarts.end(), at);
    if (after == gFunctionStarts.begin()) return "?";
    uintptr_t start = *std::prev(after);
    if (named && (uintptr_t)info.dli_saddr == start) return info.dli_sname;
    auto method = std::lower_bound(gMethods.begin(), gMethods.end(), std::make_pair(start, std::string()));
    if (method != gMethods.end() && method->first == start) return method->second;
    return "?";
}
