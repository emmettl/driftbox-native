#if defined(__linux__) && !defined(__ANDROID__)
#include "DriftboxLinuxUI.h"
#include <pango/pangocairo.h>
#include <math.h>
#include <string.h>

typedef struct { PangoFont *font; PangoGlyph special; } Face;
struct db_text { PangoContext *context; GPtrArray *faces; };
static void free_face(void *pointer) {
    Face *face = pointer;
    g_object_unref(face->font);
    g_free(face);
}
db_text *db_text_new(void) {
    db_text *text = g_new0(db_text, 1);
    text->context = pango_font_map_create_context(pango_cairo_font_map_get_default());
    text->faces = g_ptr_array_new_with_free_func(free_face);
    return text;
}
void db_text_free(db_text *text) {
    g_ptr_array_unref(text->faces);
    g_object_unref(text->context);
    g_free(text);
}
static intptr_t face_id(db_text *text, PangoFont *font, PangoGlyph glyph) {
    // Pango's missing-glyph flags do not fit the shared UInt16 glyph index. Give those
    // glyphs a separate face entry, keeping the full Pango value for rasterization.
    PangoGlyph special = glyph > UINT16_MAX ? glyph : 0;
    for (guint i = 0; i < text->faces->len; i++) {
        Face *face = g_ptr_array_index(text->faces, i);
        if (face->font == font && face->special == special) return i;
    }
    Face *face = g_new0(Face, 1);
    face->font = g_object_ref(font);
    face->special = special;
    g_ptr_array_add(text->faces, face);
    return text->faces->len - 1;
}
db_line *db_text_line(db_text *text, const char *utf8, const char *families, int weight, float size) {
    PangoLayout *layout = pango_layout_new(text->context);
    PangoFontDescription *description = pango_font_description_new();
    pango_font_description_set_family(description, families);
    pango_font_description_set_weight(description, weight);
    pango_font_description_set_absolute_size(description, size * PANGO_SCALE);
    pango_layout_set_font_description(layout, description);
    pango_font_description_free(description);
    pango_layout_set_single_paragraph_mode(layout, TRUE);
    pango_layout_set_text(layout, utf8, -1);
    db_line *line = g_new0(db_line, 1);
    PangoRectangle logical;
    pango_layout_get_extents(layout, NULL, &logical);
    int baseline = pango_layout_get_baseline(layout);
    line->width = (float)logical.width / PANGO_SCALE;
    line->ascent = (float)baseline / PANGO_SCALE;
    line->descent = (float)(logical.height - baseline) / PANGO_SCALE;
    GArray *glyphs = g_array_new(FALSE, FALSE, sizeof(db_glyph));
    PangoLayoutIter *iter = pango_layout_get_iter(layout);
    do {
        PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
        if (!run) continue;
        PangoFont *font = run->item->analysis.font;
        pango_layout_iter_get_run_extents(iter, NULL, &logical);
        float pen = (float)logical.x / PANGO_SCALE;
        float y = (float)(pango_layout_iter_get_baseline(iter) - baseline) / PANGO_SCALE;
        if (!line->family[0]) {
            PangoFontDescription *actual = pango_font_describe(font);
            g_strlcpy(line->family, pango_font_description_get_family(actual), sizeof(line->family));
            pango_font_description_free(actual);
        }
        for (int i = 0; i < run->glyphs->num_glyphs; i++) {
            PangoGlyphInfo *info = &run->glyphs->glyphs[i];
            if (info->glyph != PANGO_GLYPH_EMPTY) {
                db_glyph glyph = { .face = face_id(text, font, info->glyph),
                    .index = info->glyph <= UINT16_MAX ? info->glyph : 0,
                    .x = pen + (float)info->geometry.x_offset / PANGO_SCALE,
                    .y = y - (float)info->geometry.y_offset / PANGO_SCALE };
                g_array_append_val(glyphs, glyph);
            }
            pen += (float)info->geometry.width / PANGO_SCALE;
        }
    } while (pango_layout_iter_next_run(iter));
    pango_layout_iter_free(iter);
    line->count = glyphs->len;
    line->glyphs = (db_glyph *)g_array_free(glyphs, FALSE);
    g_object_unref(layout);
    return line;
}
void db_line_free(db_line *line) { g_free(line->glyphs); g_free(line); }
db_coverage *db_text_coverage(db_text *text, intptr_t face_id, uint16_t index, float offset) {
    if (face_id < 0 || (uintptr_t)face_id >= text->faces->len) return NULL;
    Face *face = g_ptr_array_index(text->faces, face_id);
    PangoGlyph glyph = face->special ? face->special : index;
    PangoRectangle ink;
    pango_font_get_glyph_extents(face->font, glyph, &ink, NULL);
    if (ink.width <= 0 || ink.height <= 0) return NULL;
    db_coverage *coverage = g_new0(db_coverage, 1);
    coverage->left = floorf((float)ink.x / PANGO_SCALE + offset) - 1;
    coverage->top = floorf((float)ink.y / PANGO_SCALE) - 1;
    coverage->width = ceilf((float)(ink.x + ink.width) / PANGO_SCALE + offset) - coverage->left + 1;
    coverage->height = ceilf((float)(ink.y + ink.height) / PANGO_SCALE) - coverage->top + 1;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_A8, coverage->width, coverage->height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface); g_free(coverage); return NULL;
    }
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgba(cr, 1, 1, 1, 1);
    cairo_move_to(cr, offset - coverage->left, -coverage->top);
    PangoGlyphString *single = pango_glyph_string_new();
    pango_glyph_string_set_size(single, 1);
    single->glyphs[0] = (PangoGlyphInfo){ .glyph = glyph, .geometry = { 0, 0, 0 } };
    single->log_clusters[0] = 0;
    pango_cairo_show_glyph_string(cr, face->font, single);
    pango_glyph_string_free(single);
    cairo_destroy(cr);
    cairo_surface_flush(surface);
    int stride = cairo_image_surface_get_stride(surface);
    const unsigned char *pixels = cairo_image_surface_get_data(surface);
    coverage->bytes = g_malloc((size_t)coverage->width * coverage->height);
    for (int y = 0; y < coverage->height; y++)
        memcpy(coverage->bytes + y * coverage->width, pixels + y * stride, coverage->width);
    cairo_surface_destroy(surface);
    return coverage;
}
void db_coverage_free(db_coverage *coverage) { g_free(coverage->bytes); g_free(coverage); }
#endif
