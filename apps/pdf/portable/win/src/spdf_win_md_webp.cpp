/* spdf_win_md_webp.cpp -- see spdf_win_md_webp.h. */
#include "spdf_win_md_webp.h"

#include "spdf_win_md_images.h"
#include "spdf_win_paths.h"

#include <windows.h>
#include <wincodec.h>

#include <stdio.h>
#include <string.h>

#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

namespace {

template <class T> void release(T*& p) {
    if (p) {
        p->Release();
        p = NULL;
    }
}

int to_wide(const char* utf8, wchar_t* out, size_t units) {
    return spdf_win_utf16_from_utf8(utf8, out, units) != SPDF_WIN_CONV_ERROR;
}

int ends_fold(const char* s, const char* suffix) {
    size_t n, m;
    if (!s || !suffix) return 0;
    n = strlen(s);
    m = strlen(suffix);
    return n > m && _stricmp(s + n - m, suffix) == 0;
}

/* COM on this thread, borrowed rather than owned when the caller already chose
 * an apartment -- the same rule spdf_win_d2d.cpp:107 follows. A render worker
 * has usually initialized nothing; the UI thread is apartment-threaded. */
struct com_scope {
    bool owned;
    com_scope() : owned(false) {
        HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
        if (SUCCEEDED(hr)) owned = true;
    }
    ~com_scope() {
        if (owned) CoUninitialize();
    }
};

/* Size and last-write time as two 64-bit numbers; 0/0 when the file is gone,
 * which still produces a stable (if useless) name -- the transcode then fails
 * and the hook answers 0. */
void file_stamp(const wchar_t* path, unsigned long long* size, unsigned long long* mtime) {
    WIN32_FILE_ATTRIBUTE_DATA info;
    *size = 0;
    *mtime = 0;
    if (!GetFileAttributesExW(path, GetFileExInfoStandard, &info)) return;
    *size = ((unsigned long long)info.nFileSizeHigh << 32) | info.nFileSizeLow;
    *mtime = ((unsigned long long)info.ftLastWriteTime.dwHighDateTime << 32) | info.ftLastWriteTime.dwLowDateTime;
}

HRESULT encode_png(IWICImagingFactory* wic, IWICBitmapSource* source, const wchar_t* path) {
    IWICStream* stream = NULL;
    IWICBitmapEncoder* encoder = NULL;
    IWICBitmapFrameEncode* frame = NULL;
    IWICBitmapSource* converted = NULL;
    IPropertyBag2* options = NULL;
    GUID format = GUID_WICPixelFormat32bppBGRA;
    UINT w = 0, h = 0;

    HRESULT hr = source->GetSize(&w, &h);
    if (SUCCEEDED(hr) && (w == 0 || h == 0)) hr = E_FAIL;
    /* Straight alpha, not premultiplied: a PNG's alpha is straight, and a WebP
     * with transparency would otherwise darken where it is partly clear. */
    if (SUCCEEDED(hr)) hr = WICConvertBitmapSource(GUID_WICPixelFormat32bppBGRA, source, &converted);
    if (SUCCEEDED(hr)) hr = wic->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(path, GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = wic->CreateEncoder(GUID_ContainerFormatPng, NULL, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &options);
    if (SUCCEEDED(hr)) hr = frame->Initialize(options);
    if (SUCCEEDED(hr)) hr = frame->SetSize(w, h);
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) hr = frame->WriteSource(converted, NULL);
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();

    release(options);
    release(frame);
    release(encoder);
    release(stream);
    release(converted);
    return hr;
}

} // namespace

/* --- pure -------------------------------------------------------------------- */

int spdf_win_md_webp_is_webp_name(const char* path) {
    return ends_fold(path, ".webp");
}

int spdf_win_md_webp_is_webp_bytes(const void* data, size_t len) {
    const unsigned char* p = (const unsigned char*)data;
    if (!p || len < 12) return 0;
    return memcmp(p, "RIFF", 4) == 0 && memcmp(p + 8, "WEBP", 4) == 0;
}

int spdf_win_md_webp_file_is_webp(const char* path_utf8) {
    wchar_t wide[2048];
    unsigned char head[12];
    DWORD got = 0;
    HANDLE h;
    int webp;

    if (!path_utf8 || !to_wide(path_utf8, wide, 2048)) return 0;
    h = CreateFileW(wide, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    webp = ReadFile(h, head, sizeof(head), &got, NULL) && spdf_win_md_webp_is_webp_bytes(head, got);
    CloseHandle(h);
    return webp;
}

void spdf_win_md_webp_cache_name(const char* path, unsigned long long size, unsigned long long mtime, char* out,
                                 size_t cap) {
    unsigned long long h = 1469598103934665603ULL;
    const char* p;
    int i;

    /* Case-folded: Windows paths are case-insensitive, so "A.WEBP" and "a.webp"
     * are one file and must be one cache entry. */
    for (p = path ? path : ""; *p; ++p) {
        h ^= (unsigned char)((*p >= 'A' && *p <= 'Z') ? *p + 32 : *p);
        h *= 1099511628211ULL;
    }
    for (i = 0; i < 8; ++i) {
        h ^= (unsigned char)((size >> (i * 8)) & 0xFF);
        h *= 1099511628211ULL;
    }
    for (i = 0; i < 8; ++i) {
        h ^= (unsigned char)((mtime >> (i * 8)) & 0xFF);
        h *= 1099511628211ULL;
    }
    snprintf(out, cap, "%016llx.png", h);
}

/* --- the transcode ------------------------------------------------------------ */

int spdf_win_md_webp_transcode(const char* src_utf8, const char* dst_utf8) {
    wchar_t src[2048], dst[2048], temp[2100];
    IWICImagingFactory* wic = NULL;
    IWICBitmapDecoder* decoder = NULL;
    IWICBitmapFrameDecode* frame = NULL;
    HRESULT hr;
    int ok = 0;

    if (!src_utf8 || !dst_utf8) return 0;
    if (!to_wide(src_utf8, src, 2048) || !to_wide(dst_utf8, dst, 2048)) return 0;
    _snwprintf_s(temp, 2100, _TRUNCATE, L"%s.%lu.part", dst, (unsigned long)GetCurrentThreadId());

    com_scope com;
    hr = CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
    if (SUCCEEDED(hr))
        /* WICDecodeMetadataCacheOnLoad, so the file handle is not held open past
         * the decode -- the picture may be replaced under us. */
        hr = wic->CreateDecoderFromFilename(src, NULL, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder);
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr)) hr = encode_png(wic, frame, temp);
    if (SUCCEEDED(hr)) ok = MoveFileExW(temp, dst, MOVEFILE_REPLACE_EXISTING) != 0;
    if (!ok) DeleteFileW(temp);

    release(frame);
    release(decoder);
    release(wic);
    return ok;
}

/* --- the core hook ------------------------------------------------------------- */

int spdf_win_md_webp_lookup(void* user, const char* abs_path, char* name_out, size_t cap) {
    char dir[1024], dst[2048], name[64];
    wchar_t wide[2048], wide_dst[2048];
    unsigned long long size = 0, mtime = 0;

    (void)user;
    if (!abs_path || !name_out || !cap) return 0;
    /* The name first, so the local hook -- always called with a ".webp" -- costs
     * no read at all; the byte sniff is for a cached https image. */
    if (!spdf_win_md_webp_is_webp_name(abs_path) && !spdf_win_md_webp_file_is_webp(abs_path)) return 0;
    if (!to_wide(abs_path, wide, 2048)) return 0;
    file_stamp(wide, &size, &mtime);
    if (size == 0) return 0; /* missing, empty, or unreadable: keep the fallback */

    spdf_win_md_webp_cache_name(abs_path, size, mtime, name, sizeof(name));
    if (strlen(name) >= cap) return 0;
    if (!spdf_win_md_images_dir(dir, sizeof(dir))) return 0;
    if (!spdf_win_path_join(dir, name, dst, sizeof(dst))) return 0;

    /* Already transcoded, by this open or an earlier one. */
    if (to_wide(dst, wide_dst, 2048) && GetFileAttributesW(wide_dst) != INVALID_FILE_ATTRIBUTES) {
        strcpy(name_out, name);
        return 1;
    }
    if (!spdf_win_md_webp_transcode(abs_path, dst)) return 0;
    strcpy(name_out, name);
    return 1;
}
