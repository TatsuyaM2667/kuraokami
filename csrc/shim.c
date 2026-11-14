// Thin C shim: FreeType/HarfBuzz/fontconfig/stb_image/zlib behind a flat ABI so Odin needs no struct layouts.
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#include <zlib.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifndef _WIN32
#include <fontconfig/fontconfig.h>
#endif
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#include "stb_image.h"

typedef struct {
    FT_Face ft;
    hb_font_t *hb;
} KFace;

static FT_Library lib;
static hb_buffer_t *hbuf;

int kf_init(void) {
    if (FT_Init_FreeType(&lib)) return 0;
    hbuf = hb_buffer_create();
#ifndef _WIN32
    return FcInit();
#else
    return 1;
#endif
}

#ifdef _WIN32
// No fontconfig on Windows: probe well-known files in the system font directory.
static int has_cp(const char *path, unsigned cp) {
    FT_Face f;
    if (FT_New_Face(lib, path, 0, &f)) return 0;
    int ok = FT_Get_Char_Index(f, cp) != 0;
    FT_Done_Face(f);
    return ok;
}
int kf_find(const char *family, int bold, int italic, unsigned cp, char *out, int outlen) {
    const char *dir = getenv("WINDIR");
    if (!dir) dir = "C:\\Windows";
    static const char *mono[4] = {"consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf"};
    static const char *fb[] = {"seguiemj.ttf", "YuGothM.ttc", "msgothic.ttc", "malgun.ttf", "msyh.ttc", "seguisym.ttf", "arialuni.ttf", "segoeui.ttf", 0};
    char path[1024];
    if (!cp) {
        if (family && *family && strchr(family, '.')) { // explicit file name, e.g. "CascadiaMono.ttf"
            snprintf(path, sizeof path, "%s\\Fonts\\%s", dir, family);
            FILE *t = fopen(path, "rb");
            if (t) { fclose(t); strncpy(out, path, outlen - 1); out[outlen - 1] = 0; return 1; }
        }
        snprintf(path, sizeof path, "%s\\Fonts\\%s", dir, mono[(bold ? 1 : 0) + (italic ? 2 : 0)]);
        strncpy(out, path, outlen - 1); out[outlen - 1] = 0;
        return 1;
    }
    for (int i = 0; fb[i]; i++) {
        if (family && strcmp(family, "emoji") == 0 && i > 0) break;
        snprintf(path, sizeof path, "%s\\Fonts\\%s", dir, fb[i]);
        if (has_cp(path, cp)) { strncpy(out, path, outlen - 1); out[outlen - 1] = 0; return 1; }
    }
    return 0;
}
#else
// Resolve family+style to a file path via fontconfig. If cp>0, require the font to cover that codepoint.
int kf_find(const char *family, int bold, int italic, unsigned cp, char *out, int outlen) {
    FcPattern *p = FcPatternCreate();
    if (family && *family) FcPatternAddString(p, FC_FAMILY, (const FcChar8 *)family);
    FcPatternAddInteger(p, FC_WEIGHT, bold ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR);
    FcPatternAddInteger(p, FC_SLANT, italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
    if (!cp) FcPatternAddInteger(p, FC_SPACING, FC_MONO);
    FcCharSet *cs = NULL;
    if (cp) { cs = FcCharSetCreate(); FcCharSetAddChar(cs, cp); FcPatternAddCharSet(p, FC_CHARSET, cs); }
    FcConfigSubstitute(NULL, p, FcMatchPattern);
    FcDefaultSubstitute(p);
    FcResult r; FcPattern *m = FcFontMatch(NULL, p, &r);
    int ok = 0;
    if (m) {
        FcChar8 *file; FcCharSet *mcs;
        int covers = !cp || (FcPatternGetCharSet(m, FC_CHARSET, 0, &mcs) == FcResultMatch && FcCharSetHasChar(mcs, cp));
        if (covers && FcPatternGetString(m, FC_FILE, 0, &file) == FcResultMatch) {
            strncpy(out, (const char *)file, outlen - 1); out[outlen - 1] = 0; ok = 1;
        }
        FcPatternDestroy(m);
    }
    if (cs) FcCharSetDestroy(cs);
    FcPatternDestroy(p);
    return ok;
}
#endif

void *kf_open(const char *path, int px) {
    FT_Face f;
    if (FT_New_Face(lib, path, 0, &f)) return NULL;
    if (FT_IS_SCALABLE(f)) FT_Set_Pixel_Sizes(f, 0, px);
    else if (f->num_fixed_sizes > 0) FT_Select_Size(f, 0); // bitmap color emoji (e.g. Noto Color Emoji)
    KFace *k = calloc(1, sizeof *k);
    k->ft = f;
    k->hb = hb_ft_font_create_referenced(f);
    return k;
}
void kf_close(void *p) {
    KFace *k = p;
    hb_font_destroy(k->hb);
    FT_Done_Face(k->ft);
    free(k);
}

// Cell metrics in pixels: advance of 'M', ascender, descender (negative), line height.
void kf_metrics(void *p, int *adv, int *asc, int *desc, int *height) {
    FT_Face f = ((KFace *)p)->ft;
    FT_Load_Char(f, 'M', FT_LOAD_DEFAULT);
    *adv = (int)((f->glyph->advance.x + 63) >> 6);
    *asc = (int)((f->size->metrics.ascender + 63) >> 6);
    *desc = (int)(f->size->metrics.descender >> 6);
    *height = *asc - *desc;
}

unsigned kf_glyph_index(void *p, unsigned cp) { return FT_Get_Char_Index(((KFace *)p)->ft, cp); }
int kf_has(void *p, unsigned cp) { return kf_glyph_index(p, cp) != 0; }

// Rasterize glyph id. *color=1 means BGRA bitmap (emoji), else 8-bit coverage.
// *scale is the factor to apply for fixed-size bitmap fonts so they match px.
int kf_render_glyph(void *p, unsigned gi, int px, int *w, int *h, int *left, int *top, int *pitch,
                    int *color, float *scale, unsigned char **buf) {
    FT_Face f = ((KFace *)p)->ft;
    if (FT_Load_Glyph(f, gi, FT_LOAD_RENDER | FT_LOAD_COLOR | FT_LOAD_TARGET_LIGHT)) return 0;
    FT_GlyphSlot g = f->glyph;
    *w = g->bitmap.width; *h = g->bitmap.rows; *left = g->bitmap_left; *top = g->bitmap_top;
    *pitch = g->bitmap.pitch; *buf = g->bitmap.buffer;
    *color = g->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA;
    *scale = 1.0f;
    if (!FT_IS_SCALABLE(f) && f->num_fixed_sizes > 0) *scale = (float)px / (float)(f->available_sizes[0].y_ppem >> 6);
    return 1;
}

// Shape UTF-32 text. Cluster values are indices into `text`. Positions are in 1/64 px.
int kf_shape(void *p, const unsigned *text, int len, int ligatures, unsigned *gids, unsigned *clusters,
             int *xadv, int *xoff, int *yoff, int max) {
    KFace *k = p;
    hb_buffer_clear_contents(hbuf);
    hb_buffer_add_codepoints(hbuf, text, len, 0, len);
    hb_buffer_guess_segment_properties(hbuf);
    static hb_feature_t off[3];
    static int init = 0;
    if (!init) {
        hb_feature_from_string("-liga", -1, &off[0]);
        hb_feature_from_string("-calt", -1, &off[1]);
        hb_feature_from_string("-dlig", -1, &off[2]);
        init = 1;
    }
    hb_shape(k->hb, hbuf, ligatures ? NULL : off, ligatures ? 0 : 3);
    unsigned n;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(hbuf, &n);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(hbuf, &n);
    if ((int)n > max) n = max;
    for (unsigned i = 0; i < n; i++) {
        gids[i] = info[i].codepoint; clusters[i] = info[i].cluster;
        xadv[i] = pos[i].x_advance; xoff[i] = pos[i].x_offset; yoff[i] = pos[i].y_offset;
    }
    return (int)n;
}

unsigned char *kf_image_decode(const unsigned char *data, int len, int *w, int *h) {
    int n; return stbi_load_from_memory(data, len, w, h, &n, 4);
}
void kf_free(void *p) { free(p); }

// zlib inflate into a malloc'd buffer; returns length or -1.
long kf_inflate(const unsigned char *src, long len, unsigned char **out) {
    z_stream s = {0};
    if (inflateInit(&s) != Z_OK) return -1;
    long cap = len * 4 + 1024, n = 0;
    unsigned char *b = malloc(cap);
    s.next_in = (unsigned char *)src; s.avail_in = len;
    int rc;
    do {
        if (n == cap) { cap *= 2; b = realloc(b, cap); }
        s.next_out = b + n; s.avail_out = cap - n;
        rc = inflate(&s, Z_NO_FLUSH);
        n = cap - s.avail_out;
    } while (rc == Z_OK);
    inflateEnd(&s);
    if (rc != Z_STREAM_END) { free(b); return -1; }
    *out = b; return n;
}
