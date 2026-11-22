#ifndef SPDF_CAMERA_RAW_H
#define SPDF_CAMERA_RAW_H

/* Camera RAW photos (Canon CR2/CR3/CRW, Nikon NEF/NRW, Sony ARW/SR2/SRF, Olympus ORF, Fujifilm RAF, Panasonic and
 * Leica RW2/RWL, Pentax PEF, DNG, Samsung SRW, Hasselblad 3FR/FFF, Phase One IIQ, Sigma X3F), shown as pictures.
 *
 * A frontend installs this with its own full RAW decoder (the Mac: Core Image, mac/SPDFMacCameraRaw.mm) or with
 * none (Linux, Windows). Without a decoder, or when it cannot read a file, the photo is shown from the largest JPEG
 * preview the camera stored inside it, turned upright from the RAW file's orientation tag. Most cameras store one:
 * full size from most Canon, Nikon, Pentax and Samsung bodies, 1600 to 3200 pixels wide from Sony, Olympus, Fujifilm
 * and Panasonic, 640 pixels from older compacts; Hasselblad and Phase One files may hold none.
 *
 * The headerless sensor frames of spdf_sensor_raw.h keep the .raw extension; none of it is claimed here. */

#include "mupdf/fitz.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when the path names a camera RAW photo by its extension. */
int spdf_camera_raw_path(const char* path);

/* The frontend's full decoder: the developed photo, upright, as a one-page document. Returns NULL or throws when it
 * cannot read the file; the embedded preview is tried next. */
typedef fz_document* (*spdf_camera_raw_decoder)(fz_context* ctx, const char* path);

/* Opens every camera RAW path through spdf_open from now on. decoder may be NULL (preview only). Call before any
 * document opens. */
void spdf_camera_raw_install(spdf_camera_raw_decoder decoder);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_CAMERA_RAW_H */
