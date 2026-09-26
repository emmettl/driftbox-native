#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct db_text db_text;
typedef struct { intptr_t face; uint16_t index; float x, y; } db_glyph;
typedef struct {
    db_glyph *glyphs;
    int count;
    float width, ascent, descent;
    char family[128];
} db_line;
typedef struct { int width, height, left, top; uint8_t *bytes; } db_coverage;
db_text *db_text_new(void);
void db_text_free(db_text *text);
db_line *db_text_line(db_text *text, const char *utf8, const char *families, int weight, float size);
void db_line_free(db_line *line);
db_coverage *db_text_coverage(db_text *text, intptr_t face, uint16_t index, float offset);
void db_coverage_free(db_coverage *coverage);

typedef struct db_window db_window;
// All callbacks execute on GTK's main thread. kind: 1 down/move, 2 up, 3 space, 4 focus lost.
typedef void (*db_draw)(void *, int width, int height, int scale);
typedef void (*db_event)(void *, int kind, double x, double y);
typedef void (*db_cleanup)(void *);
db_window *db_window_new(void *context, db_draw draw, db_event event, db_cleanup cleanup,
                         char *error, size_t size);
void db_window_run(db_window *window);
void db_window_close(db_window *window);
void db_window_free(db_window *window);
void db_window_title(db_window *window, const char *title);
void db_window_resize(db_window *window, int width, int height);
void db_window_visible(db_window *window, int visible);
const char *db_window_error(db_window *window);
