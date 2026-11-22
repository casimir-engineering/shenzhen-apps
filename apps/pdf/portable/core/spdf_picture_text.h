#ifndef SPDF_PICTURE_TEXT_H
#define SPDF_PICTURE_TEXT_H

/* The text recognised in a picture (a photo, a screenshot, a scan saved as an image), laid over it as invisible text so
 * it selects, copies and finds like a scanned PDF's text layer. The picture is opened as MuPDF opens it and wrapped in
 * a document whose pages run the picture, then the words the frontend recognised. The words are asked for every time
 * a page runs, so text recognised after the picture opened shows at the next selection or search without reopening.
 *
 * The macOS reader installs this (mac/SPDFMacPictureText.mm); the GTK and Windows readers link nothing new. */

#ifdef __cplusplus
extern "C" {
#endif

/* One recognised word: its text (UTF-8) and its box as fractions of the page (0..1, from the top left). Words of one
 * line share `line` and come in reading order, so a space is laid between them. */
typedef struct spdf_picture_word {
    float x0, y0, x1, y1;
    int line;
    const char* text;
} spdf_picture_word;

/* Whether `path` is a picture that may have recognised text (only these are wrapped). */
typedef int (*spdf_picture_text_wants)(const char* path);
/* The words on page `page_index` of the picture at `path`, as one malloc'd block the caller frees (the texts live in
 * it); returns the count, 0 with *words NULL when there are none. Called from any thread. */
typedef int (*spdf_picture_text_lookup)(const char* path, int page_index, spdf_picture_word** words);

void spdf_picture_text_install(spdf_picture_text_wants wants, spdf_picture_text_lookup lookup);

#ifdef __cplusplus
}
#endif

#endif /* SPDF_PICTURE_TEXT_H */
