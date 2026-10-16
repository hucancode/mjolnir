// Text metrics and glyph quads over one TTF/OTF font, rasterized on demand into an R8 atlas.
// No GPU: a UI measures with it (measure, line_height); a renderer draws its glyphs and
// uploads its atlas. init and destroy bracket a font.
package font
