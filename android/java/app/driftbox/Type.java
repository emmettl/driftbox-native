package app.driftbox;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.fonts.Font;
import android.graphics.fonts.FontVariationAxis;
import android.graphics.text.PositionedGlyphs;
import android.graphics.text.TextRunShaper;
import android.os.Build;
import android.util.Log;
import android.util.Xml;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import org.xmlpull.v1.XmlPullParser;

/**
 * Type, for Swift's {@code AndroidTypesetter}: Android's own text stack, which is Minikin and
 * HarfBuzz underneath, so a line is shaped and kerned as the font says, as a browser's canvas does
 * it. A line is set by {@link TextRunShaper}, and a glyph drawn by {@link Canvas#drawGlyphs} into
 * an alpha bitmap. Both are Android 12's, and the typesetter is not made on anything older.
 *
 * <p>Swift calls in from whichever thread it draws on, so everything here is behind one lock.
 */
final class Type {
  private Type() {}

  /** The family used when none of those asked for is one Android has. */
  static final String FALLBACK = "sans-serif";

  /** Every face a line has been set in, numbered by where it is in this list. */
  private static final ArrayList<Face> faces = new ArrayList<>();
  private static final HashMap<Face, Integer> faceNumbers = new HashMap<>();
  private static final HashMap<String, Paint> paints = new HashMap<>();
  private static Set<String> families;
  /** What glyphs are drawn with: only its size and its emboldening change. */
  private static final Paint ink = unhinted();

  /**
   * {@code text} set on one line in the first of {@code asked} that Android has, at {@code weight}
   * and {@code size} pixels to the em: the pen's travel, the font's ascent and descent, which of
   * those asked for was used or -1, and then four numbers a glyph, its face, its index and its
   * origin's x and y.
   */
  static synchronized float[] line(String text, String[] asked, int weight, float size) {
    int chosen = choose(asked);
    Paint paint = paint(chosen < 0 ? FALLBACK : asked[chosen], weight, size);
    PositionedGlyphs run =
        TextRunShaper.shapeTextRun(text, 0, text.length(), 0, text.length(), 0, 0, false, paint);
    Paint.FontMetrics metrics = paint.getFontMetrics();
    int count = run.glyphCount();
    float[] out = new float[4 + count * 4];
    out[0] = run.getAdvance();
    out[1] = -metrics.ascent;
    out[2] = metrics.descent;
    out[3] = chosen;
    for (int i = 0; i < count; i++) {
      out[4 + i * 4] = face(run, i, weight);
      out[5 + i * 4] = run.getGlyphId(i);
      out[6 + i * 4] = run.getGlyphX(i);
      out[7 + i * 4] = run.getGlyphY(i);
    }
    return out;
  }

  /**
   * What glyph {@code glyph} of face {@code face} covers at {@code size}, its origin {@code offset}
   * pixels into a pixel: four little-endian ints, the bitmap's width, height, left and top relative
   * to the origin's pixel, and then a byte a pixel, rows from the top. Null when it covers nothing.
   */
  static synchronized byte[] coverage(int face, int glyph, float size, float offset) {
    if (face < 0 || face >= faces.size()) return null;
    Face drawn = faces.get(face);
    Paint paint = ink;
    paint.setTextSize(size);
    paint.setFakeBoldText(drawn.bold);
    RectF bounds = new RectF();
    drawn.font.getGlyphBounds(glyph, paint, bounds);
    if (bounds.isEmpty()) return null;
    // A pixel spare all round, for the antialiasing to fall into, and room for emboldening, which
    // thickens the outline by about a twenty-fourth of the em beyond the bounds the font gives.
    int spare = drawn.bold ? (int) Math.ceil(size / 24) + 1 : 1;
    int left = (int) Math.floor(bounds.left + offset) - spare;
    int right = (int) Math.ceil(bounds.right + offset) + spare;
    int top = (int) Math.floor(bounds.top) - spare;
    int bottom = (int) Math.ceil(bounds.bottom) + spare;
    int width = right - left;
    int height = bottom - top;
    Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ALPHA_8);
    new Canvas(bitmap)
        .drawGlyphs(new int[] {glyph}, 0, new float[] {offset - left, -top}, 0, 1, drawn.font, paint);
    ByteBuffer pixels = ByteBuffer.allocate(bitmap.getRowBytes() * height);
    bitmap.copyPixelsToBuffer(pixels);
    bitmap.recycle();
    ByteBuffer out = ByteBuffer.allocate(16 + width * height).order(ByteOrder.LITTLE_ENDIAN);
    out.putInt(width).putInt(height).putInt(left).putInt(top);
    byte[] rows = pixels.array();
    for (int y = 0; y < height; y++) out.put(rows, y * bitmap.getRowBytes(), width);
    return out.array();
  }

  /** Which of {@code asked} Android has, the first of them, or -1 for none. */
  private static int choose(String[] asked) {
    if (families == null) families = readFamilies();
    for (int i = 0; i < asked.length; i++) {
      if (families.contains(asked[i].toLowerCase(Locale.ROOT))) return i;
    }
    return -1;
  }

  /**
   * A paint set up as a canvas draws text: antialiased, placed to fractions of a pixel, and never
   * hinted, so that a line twice the size is exactly twice as wide.
   */
  private static Paint paint(String family, int weight, float size) {
    String key = family + "/" + weight + "/" + size;
    Paint paint = paints.get(key);
    if (paint != null) return paint;
    paint = unhinted();
    Typeface base = Typeface.create(family.toLowerCase(Locale.ROOT), Typeface.NORMAL);
    paint.setTypeface(Typeface.create(base, Math.max(1, Math.min(1000, weight)), false));
    paint.setTextSize(size);
    paints.put(key, paint);
    return paint;
  }

  private static Paint unhinted() {
    Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    paint.setHinting(Paint.HINTING_OFF);
    paint.setSubpixelText(true);
    paint.setLinearText(true);
    return paint;
  }

  /**
   * The number of the face glyph {@code i} of {@code run} is drawn in, given one the first time it
   * is seen. The font a run hands back is the file Minikin chose and not how it used it: a variable
   * font such as Roboto is set at the weight asked for through its {@code wght} axis, and a face with
   * nothing that heavy is emboldened, and both have to be done again to draw the glyph as it was
   * set. Android 15 says which weight it gave the axis; before it, the weight asked for is given it,
   * which a font without the axis ignores.
   */
  private static int face(PositionedGlyphs run, int i, int weight) {
    Font font = run.getFont(i);
    float wght = Build.VERSION.SDK_INT >= 35 ? run.getWeightOverride(i) : weight;
    boolean bold = Build.VERSION.SDK_INT >= 35 && run.getFakeBold(i);
    Face key = new Face(font, wght, bold);
    Integer number = faceNumbers.get(key);
    if (number != null) return number;
    Font drawn = font;
    if (wght != PositionedGlyphs.NO_OVERRIDE) {
      ArrayList<FontVariationAxis> axes = new ArrayList<>();
      axes.add(new FontVariationAxis("wght", wght));
      if (font.getAxes() != null) {
        for (FontVariationAxis axis : font.getAxes()) {
          if (!axis.getTag().equals("wght")) axes.add(axis);
        }
      }
      try {
        drawn = new Font.Builder(font)
            .setFontVariationSettings(axes.toArray(new FontVariationAxis[0]))
            .build();
      } catch (IOException | IllegalArgumentException e) {
        Log.w(Main.TAG, "could not weight " + font + ": " + e);
      }
    }
    faces.add(new Face(drawn, wght, bold));
    faceNumbers.put(key, faces.size() - 1);
    return faces.size() - 1;
  }

  /** A font as a line was set in it: the file, the weight given its axis, and whether emboldened. */
  private static final class Face {
    final Font font;
    final float wght;
    final boolean bold;

    Face(Font font, float wght, boolean bold) {
      this.font = font;
      this.wght = wght;
      this.bold = bold;
    }

    @Override
    public boolean equals(Object other) {
      return other instanceof Face
          && ((Face) other).font.equals(font)
          && ((Face) other).wght == wght
          && ((Face) other).bold == bold;
    }

    @Override
    public int hashCode() {
      return font.hashCode() * 31 + Float.hashCode(wght) * 2 + (bold ? 1 : 0);
    }
  }

  /**
   * The family names Android answers to, each a family or an alias of one, as {@code fonts.xml}
   * lists them: {@link Typeface#create(String, int)} answers a name it does not have with its
   * default rather than with nothing, and so cannot say itself whether it had it. Arial is here,
   * as another name for sans-serif.
   */
  private static Set<String> readFamilies() {
    Set<String> names = new HashSet<>(Arrays.asList("sans-serif", "serif", "monospace"));
    for (String path : new String[] {"/system/etc/fonts.xml", "/product/etc/fonts_customization.xml"}) {
      try (InputStream in = new FileInputStream(path)) {
        XmlPullParser parser = Xml.newPullParser();
        parser.setInput(in, null);
        for (int event = parser.getEventType(); event != XmlPullParser.END_DOCUMENT; event = parser.next()) {
          if (event != XmlPullParser.START_TAG) continue;
          if (!parser.getName().equals("family") && !parser.getName().equals("alias")) continue;
          String name = parser.getAttributeValue(null, "name");
          if (name != null) names.add(name.toLowerCase(Locale.ROOT));
        }
      } catch (Exception e) {
        if (!path.startsWith("/product")) Log.w(Main.TAG, "no font names from " + path + ": " + e);
      }
    }
    return names;
  }
}
