// Text metrics and glyph quads over one TTF/OTF font, rasterized on demand
// into an R8 atlas. Layer 1: no GPU, no other module. A UI measures with it;
// a renderer draws its glyphs and uploads its atlas.
package font
