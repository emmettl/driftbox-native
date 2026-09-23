// DirectWrite as C, which its own headers are not: `dwrite.h` declares its interfaces as C++
// classes only, so nothing in Swift can import them. What is here is the part the typesetter
// calls, transcribed from `dwrite.h` in the order its vtables are laid out, which COM never
// changes. A method nothing here calls keeps its slot as `void *`, so the ones after it land where
// they are. Only the declarations; every call is made from Swift.
#pragma once
#ifdef _WIN32
// What these build on is inside Swift's WinSDK module, where an #include of it again is a no-op;
// importing the module is what makes it visible here.
#pragma clang module import WinSDK
#include <windows.h>

// A measuring mode is `dcommon.h`'s enum, which WinSDK keeps in a submodule of its own; it is an
// int, so it is declared as one here, and natural measuring is its zero.
#define CDIRECTWRITE_MEASURING_NATURAL 0

typedef struct IDWriteFactory IDWriteFactory;
typedef struct IDWriteFontCollection IDWriteFontCollection;
typedef struct IDWriteTextFormat IDWriteTextFormat;
typedef struct IDWriteTextLayout IDWriteTextLayout;
typedef struct IDWriteFontFace IDWriteFontFace;
typedef struct IDWriteGlyphRunAnalysis IDWriteGlyphRunAnalysis;
typedef struct IDWriteTextRenderer IDWriteTextRenderer;

typedef enum DWRITE_FACTORY_TYPE { DWRITE_FACTORY_TYPE_SHARED = 0 } DWRITE_FACTORY_TYPE;
typedef enum DWRITE_FONT_STYLE { DWRITE_FONT_STYLE_NORMAL = 0 } DWRITE_FONT_STYLE;
typedef enum DWRITE_FONT_STRETCH { DWRITE_FONT_STRETCH_NORMAL = 5 } DWRITE_FONT_STRETCH;
typedef enum DWRITE_WORD_WRAPPING { DWRITE_WORD_WRAPPING_NO_WRAP = 1 } DWRITE_WORD_WRAPPING;
typedef enum DWRITE_RENDERING_MODE {
  DWRITE_RENDERING_MODE_ALIASED = 1,
  DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC = 5
} DWRITE_RENDERING_MODE;
typedef enum DWRITE_TEXTURE_TYPE {
  DWRITE_TEXTURE_ALIASED_1x1 = 0,
  DWRITE_TEXTURE_CLEARTYPE_3x1 = 1
} DWRITE_TEXTURE_TYPE;

typedef struct DWRITE_GLYPH_OFFSET {
  FLOAT advanceOffset;
  FLOAT ascenderOffset;
} DWRITE_GLYPH_OFFSET;

typedef struct DWRITE_GLYPH_RUN {
  IDWriteFontFace *fontFace;
  FLOAT fontEmSize;
  UINT32 glyphCount;
  const UINT16 *glyphIndices;
  const FLOAT *glyphAdvances;
  const DWRITE_GLYPH_OFFSET *glyphOffsets;
  BOOL isSideways;
  UINT32 bidiLevel;
} DWRITE_GLYPH_RUN;

typedef struct DWRITE_TEXT_METRICS {
  FLOAT left;
  FLOAT top;
  FLOAT width;
  FLOAT widthIncludingTrailingWhitespace;
  FLOAT height;
  FLOAT layoutWidth;
  FLOAT layoutHeight;
  UINT32 maxBidiReorderingDepth;
  UINT32 lineCount;
} DWRITE_TEXT_METRICS;

typedef struct DWRITE_FONT_METRICS {
  UINT16 designUnitsPerEm;
  UINT16 ascent;
  UINT16 descent;
  INT16 lineGap;
  UINT16 capHeight;
  UINT16 xHeight;
  INT16 underlinePosition;
  UINT16 underlineThickness;
  INT16 strikethroughPosition;
  UINT16 strikethroughThickness;
} DWRITE_FONT_METRICS;

typedef struct DWRITE_MATRIX {
  FLOAT m11, m12, m21, m22, dx, dy;
} DWRITE_MATRIX;

// Passed to a renderer's callbacks and never read, so opaque.
typedef struct DWRITE_GLYPH_RUN_DESCRIPTION DWRITE_GLYPH_RUN_DESCRIPTION;
typedef struct DWRITE_UNDERLINE DWRITE_UNDERLINE;
typedef struct DWRITE_STRIKETHROUGH DWRITE_STRIKETHROUGH;
typedef struct IDWriteInlineObject IDWriteInlineObject;

typedef struct IDWriteFactoryVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteFactory *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteFactory *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteFactory *This);
  HRESULT(STDMETHODCALLTYPE *GetSystemFontCollection)(
    IDWriteFactory *This, IDWriteFontCollection **collection, BOOL checkForUpdates);
  void *CreateCustomFontCollection;
  void *RegisterFontCollectionLoader;
  void *UnregisterFontCollectionLoader;
  void *CreateFontFileReference;
  void *CreateCustomFontFileReference;
  void *CreateFontFace;
  void *CreateRenderingParams;
  void *CreateMonitorRenderingParams;
  void *CreateCustomRenderingParams;
  void *RegisterFontFileLoader;
  void *UnregisterFontFileLoader;
  HRESULT(STDMETHODCALLTYPE *CreateTextFormat)(
    IDWriteFactory *This, const WCHAR *familyName, IDWriteFontCollection *collection, INT32 weight,
    DWRITE_FONT_STYLE style, DWRITE_FONT_STRETCH stretch, FLOAT size, const WCHAR *locale,
    IDWriteTextFormat **format);
  void *CreateTypography;
  void *GetGdiInterop;
  HRESULT(STDMETHODCALLTYPE *CreateTextLayout)(
    IDWriteFactory *This, const WCHAR *string, UINT32 length, IDWriteTextFormat *format,
    FLOAT maxWidth, FLOAT maxHeight, IDWriteTextLayout **layout);
  void *CreateGdiCompatibleTextLayout;
  void *CreateEllipsisTrimmingSign;
  void *CreateTextAnalyzer;
  void *CreateNumberSubstitution;
  HRESULT(STDMETHODCALLTYPE *CreateGlyphRunAnalysis)(
    IDWriteFactory *This, const DWRITE_GLYPH_RUN *run, FLOAT pixelsPerDip,
    const DWRITE_MATRIX *transform, DWRITE_RENDERING_MODE renderingMode,
    INT32 measuringMode, FLOAT baselineOriginX, FLOAT baselineOriginY,
    IDWriteGlyphRunAnalysis **analysis);
} IDWriteFactoryVtbl;
struct IDWriteFactory { const IDWriteFactoryVtbl *lpVtbl; };

typedef struct IDWriteFontCollectionVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteFontCollection *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteFontCollection *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteFontCollection *This);
  void *GetFontFamilyCount;
  void *GetFontFamily;
  HRESULT(STDMETHODCALLTYPE *FindFamilyName)(
    IDWriteFontCollection *This, const WCHAR *familyName, UINT32 *index, BOOL *exists);
  void *GetFontFromFontFace;
} IDWriteFontCollectionVtbl;
struct IDWriteFontCollection { const IDWriteFontCollectionVtbl *lpVtbl; };

typedef struct IDWriteTextFormatVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteTextFormat *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteTextFormat *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteTextFormat *This);
  void *SetTextAlignment;
  void *SetParagraphAlignment;
  HRESULT(STDMETHODCALLTYPE *SetWordWrapping)(IDWriteTextFormat *This, DWRITE_WORD_WRAPPING wrapping);
  // The rest of the format's 25, which a layout's vtable begins with too.
  void *SetReadingDirection, *SetFlowDirection, *SetIncrementalTabStop, *SetTrimming,
    *SetLineSpacing, *GetTextAlignment, *GetParagraphAlignment, *GetWordWrapping,
    *GetReadingDirection, *GetFlowDirection, *GetIncrementalTabStop, *GetTrimming,
    *GetLineSpacing, *GetFontCollection, *GetFontFamilyNameLength, *GetFontFamilyName,
    *GetFontWeight, *GetFontStyle, *GetFontStretch, *GetFontSize, *GetLocaleNameLength,
    *GetLocaleName;
} IDWriteTextFormatVtbl;
struct IDWriteTextFormat { const IDWriteTextFormatVtbl *lpVtbl; };

typedef struct IDWriteTextLayoutVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteTextLayout *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteTextLayout *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteTextLayout *This);
  // IDWriteTextFormat's 25, none of which a layout is called through here.
  void *format[25];
  void *SetMaxWidth, *SetMaxHeight, *SetFontCollection, *SetFontFamilyName, *SetFontWeight,
    *SetFontStyle, *SetFontStretch, *SetFontSize, *SetUnderline, *SetStrikethrough,
    *SetDrawingEffect, *SetInlineObject, *SetTypography, *SetLocaleName, *GetMaxWidth,
    *GetMaxHeight, *GetFontCollection, *GetFontFamilyNameLength, *GetFontFamilyName,
    *GetFontWeight, *GetFontStyle, *GetFontStretch, *GetFontSize, *GetUnderline,
    *GetStrikethrough, *GetDrawingEffect, *GetInlineObject, *GetTypography,
    *GetLocaleNameLength, *GetLocaleName;
  HRESULT(STDMETHODCALLTYPE *Draw)(
    IDWriteTextLayout *This, void *context, IDWriteTextRenderer *renderer, FLOAT originX,
    FLOAT originY);
  void *GetLineMetrics;
  HRESULT(STDMETHODCALLTYPE *GetMetrics)(IDWriteTextLayout *This, DWRITE_TEXT_METRICS *metrics);
  void *GetOverhangMetrics, *GetClusterMetrics, *DetermineMinWidth, *HitTestPoint,
    *HitTestTextPosition, *HitTestTextRange;
} IDWriteTextLayoutVtbl;
struct IDWriteTextLayout { const IDWriteTextLayoutVtbl *lpVtbl; };

typedef struct IDWriteFontFaceVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteFontFace *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteFontFace *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteFontFace *This);
  void *GetType, *GetFiles, *GetIndex, *GetSimulations, *IsSymbolFont;
  void(STDMETHODCALLTYPE *GetMetrics)(IDWriteFontFace *This, DWRITE_FONT_METRICS *metrics);
  void *GetGlyphCount, *GetDesignGlyphMetrics, *GetGlyphIndices, *TryGetFontTable,
    *ReleaseFontTable, *GetGlyphRunOutline, *GetRecommendedRenderingMode,
    *GetGdiCompatibleMetrics, *GetGdiCompatibleGlyphMetrics;
} IDWriteFontFaceVtbl;
struct IDWriteFontFace { const IDWriteFontFaceVtbl *lpVtbl; };

typedef struct IDWriteGlyphRunAnalysisVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteGlyphRunAnalysis *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteGlyphRunAnalysis *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteGlyphRunAnalysis *This);
  HRESULT(STDMETHODCALLTYPE *GetAlphaTextureBounds)(
    IDWriteGlyphRunAnalysis *This, DWRITE_TEXTURE_TYPE type, RECT *bounds);
  HRESULT(STDMETHODCALLTYPE *CreateAlphaTexture)(
    IDWriteGlyphRunAnalysis *This, DWRITE_TEXTURE_TYPE type, const RECT *bounds, BYTE *texture,
    UINT32 size);
  void *GetAlphaBlendParams;
} IDWriteGlyphRunAnalysisVtbl;
struct IDWriteGlyphRunAnalysis { const IDWriteGlyphRunAnalysisVtbl *lpVtbl; };

// A text renderer is what a layout draws through, and is implemented in Swift: every slot is
// declared, since DirectWrite calls all of them.
typedef struct IDWriteTextRendererVtbl {
  HRESULT(STDMETHODCALLTYPE *QueryInterface)(IDWriteTextRenderer *This, REFIID riid, void **object);
  ULONG(STDMETHODCALLTYPE *AddRef)(IDWriteTextRenderer *This);
  ULONG(STDMETHODCALLTYPE *Release)(IDWriteTextRenderer *This);
  HRESULT(STDMETHODCALLTYPE *IsPixelSnappingDisabled)(
    IDWriteTextRenderer *This, void *context, BOOL *disabled);
  HRESULT(STDMETHODCALLTYPE *GetCurrentTransform)(
    IDWriteTextRenderer *This, void *context, DWRITE_MATRIX *transform);
  HRESULT(STDMETHODCALLTYPE *GetPixelsPerDip)(IDWriteTextRenderer *This, void *context, FLOAT *pixelsPerDip);
  HRESULT(STDMETHODCALLTYPE *DrawGlyphRun)(
    IDWriteTextRenderer *This, void *context, FLOAT baselineOriginX, FLOAT baselineOriginY,
    INT32 measuringMode, const DWRITE_GLYPH_RUN *run,
    const DWRITE_GLYPH_RUN_DESCRIPTION *description, IUnknown *effect);
  HRESULT(STDMETHODCALLTYPE *DrawUnderline)(
    IDWriteTextRenderer *This, void *context, FLOAT baselineOriginX, FLOAT baselineOriginY,
    const DWRITE_UNDERLINE *underline, IUnknown *effect);
  HRESULT(STDMETHODCALLTYPE *DrawStrikethrough)(
    IDWriteTextRenderer *This, void *context, FLOAT baselineOriginX, FLOAT baselineOriginY,
    const DWRITE_STRIKETHROUGH *strikethrough, IUnknown *effect);
  HRESULT(STDMETHODCALLTYPE *DrawInlineObject)(
    IDWriteTextRenderer *This, void *context, FLOAT originX, FLOAT originY,
    IDWriteInlineObject *object, BOOL isSideways, BOOL isRightToLeft, IUnknown *effect);
} IDWriteTextRendererVtbl;
struct IDWriteTextRenderer { const IDWriteTextRendererVtbl *lpVtbl; };

HRESULT WINAPI DWriteCreateFactory(DWRITE_FACTORY_TYPE factoryType, REFIID iid, IUnknown **factory);
#endif
