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

// Shared Desktop shell. All calls and callbacks, except dispatch submission, use the main thread.
typedef struct db_desktop db_desktop;
typedef struct db_menu db_menu;
typedef struct {
    int kind, key, code, modifiers, button;
    double x, y, dx, dy;
} db_input;
typedef void (*db_input_callback)(void *, const db_input *);
typedef void (*db_command)(void *, int);
// URI text is borrowed for the duration of the callback; coordinates are logical points.
typedef void (*db_drop_callback)(void *, const char *uris, double x, double y);
typedef int (*db_can_close)(void *);
// URI lists are newline-separated (newlines in paths are URI-escaped); answer 0 means cancelled.
typedef void (*db_reply)(void *, int answer, const char *uris);
db_desktop *db_desktop_new(void *, db_draw, db_input_callback, db_command, db_can_close, db_drop_callback, char *, size_t);
int db_desktop_prepare(db_desktop *);
void db_desktop_run(db_desktop *);
void db_desktop_current(db_desktop *);
void db_desktop_close(db_desktop *);
void db_desktop_free(db_desktop *);
void db_desktop_title(db_desktop *, const char *);
const char *db_desktop_error(db_desktop *);
db_menu *db_menu_new(void);
void db_menu_free(db_menu *);
void db_menu_submenu(db_menu *, const char *, db_menu *);
void db_menu_section(db_menu *, db_menu *);
void db_menu_item(db_menu *, const char *, int);
void db_desktop_menu(db_desktop *, db_menu *);
void db_desktop_action(db_desktop *, int, int enabled, int checked);
void db_desktop_files(db_desktop *, int save, int multiple, const char *extensions,
                      const char *name, void *, db_reply);
void db_desktop_save_question(db_desktop *, const char *name, void *, db_reply);
void db_desktop_popup(db_desktop *, db_menu *, double x, double y, void *, db_reply);
