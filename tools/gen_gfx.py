#!/usr/bin/env python3
"""
gen_gfx.py - generates gfx_roms.v for the KC705 Flappy Bird design.

Contents generated:
  * gfx_palette : 5-bit palette index -> YCbCr (BT.601 limited range, 8-bit each)
  * gfx_bird    : 16x12 bird sprite, 3 wing frames, 3 bit/pixel
  * gfx_font    : 5x7 glyph ROM (glyph index -> pixel) for score + UI text
  * gfx_hill    : 64-entry hill silhouette table for the scrolling parallax band
All ROMs are combinational case statements (LUT logic, no BRAM needed).
"""
import math

# ----------------------------------------------------------------------------
# 1. Palette  (index, name, R, G, B)  -- NES-ish hues for an 8-bit look
# ----------------------------------------------------------------------------
PAL = [
    ("SKY0",     0x4C, 0x84, 0xFC),   #  0 upper sky
    ("SKY1",     0x6C, 0xA4, 0xFC),   #  1 mid sky
    ("SKY2",     0x94, 0xC4, 0xFC),   #  2 lower sky
    ("CLOUD",    0xFC, 0xFC, 0xFC),   #  3 cloud white
    ("HILL_LT",  0x54, 0xB8, 0x44),   #  4 hill light green
    ("HILL_DK",  0x2C, 0x84, 0x2C),   #  5 hill dark green
    ("BUSH_LT",  0x74, 0xD0, 0x4C),   #  6 bush highlight
    ("BUSH_DK",  0x38, 0x98, 0x30),   #  7 bush shade
    ("GRASS",    0x68, 0xD0, 0x3C),   #  8 ground grass
    ("GRASS_DK", 0x3C, 0x9C, 0x2C),   #  9 grass dither shade
    ("SAND",     0xE4, 0xC0, 0x6C),   # 10 sand
    ("SAND_DK",  0xBC, 0x94, 0x44),   # 11 sand shade
    ("PIPE",     0x58, 0xC8, 0x38),   # 12 pipe body green
    ("PIPE_HI",  0x9C, 0xEC, 0x70),   # 13 pipe highlight
    ("PIPE_DK",  0x18, 0x58, 0x1C),   # 14 pipe outline dark
    ("BIRD_Y",   0xFC, 0xD8, 0x24),   # 15 bird body yellow
    ("BIRD_O",   0xE8, 0x80, 0x20),   # 16 bird wing orange
    ("WHITE",    0xFC, 0xFC, 0xFC),   # 17 eye / white
    ("BLACK",    0x00, 0x00, 0x00),   # 18 outline black
    ("TXT",      0xFC, 0xFC, 0xFC),   # 19 UI text white
    ("TXT_SH",   0x20, 0x20, 0x20),   # 20 UI text shadow
    ("GO_RED",   0xE0, 0x40, 0x2C),   # 21 "GAME OVER" red
    ("BEAK_DK",  0xB0, 0x54, 0x10),   # 22 beak shade
    ("GROUND_E", 0x8C, 0x5C, 0x28),   # 23 ground edge brown
] + [("SPARE{}".format(i), 0x40 + 8 * i, 0x80, 0xC0 - 8 * i) for i in range(8)]

def rgb_to_ycbcr601_limited(r, g, b):
    """BT.601, 8-bit, studio/limited range (Y:16-235, C:16-240)."""
    y  =  16.0 + ( 65.481*r + 128.553*g +  24.966*b) / 255.0
    cb = 128.0 + (-37.797*r -  74.203*g + 112.000*b) / 255.0
    cr = 128.0 + (112.000*r -  93.786*g -  18.214*b) / 255.0
    return (max(16, min(235, int(round(y)))),
            max(16, min(240, int(round(cb)))),
            max(16, min(240, int(round(cr)))))

# ----------------------------------------------------------------------------
# 2. Bird sprite: 3 frames, 16 x 12, 3 bit/pixel
#    codes: 0 transparent, 1 black outline, 2 yellow body,
#           3 orange wing, 4 white eye, 5 dark-orange beak shade
# ----------------------------------------------------------------------------
BW, BH = 16, 12
BCX, BCY, BRX, BRY = 5.8, 6.2, 4.4, 4.0      # body ellipse
ECX, ECY, ER         = 7.4, 4.6, 1.6          # eye white
PCX, PCY, PR         = 7.7, 4.6, 0.7          # pupil
BEAK_X0, BEAK_CY     = 9, 6.5                 # beak starts at x=9
WCX, WRX, WRY        = 4.0, 2.6, 1.3          # wing ellipse
BEAK_TIP_X           = 13                     # x >= this -> darker beak tip

def ell(x, y, cx, cy, rx, ry):
    return ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0

def make_bird(wing_y):
    """Return 12 strings of 16 chars for one wing position."""
    g = [["." for _ in range(BW)] for _ in range(BH)]

    def body(x, y): return ell(x, y, BCX, BCY, BRX, BRY)
    def beak(x, y): return x >= BEAK_X0 and (x - BEAK_X0) + 2.0 * abs(y - BEAK_CY) <= 5.0
    def solid(x, y): return body(x, y) or beak(x, y)

    def dilated(x, y):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < BW and 0 <= ny < BH and solid(nx, ny):
                    return True
        return False

    # 1. black outline around the union of body+beak
    for y in range(BH):
        for x in range(BW):
            if dilated(x, y) and not solid(x, y):
                g[y][x] = "K"
    # 2. body and beak fill
    for y in range(BH):
        for x in range(BW):
            if body(x, y):
                g[y][x] = "Y"
            elif beak(x, y):
                g[y][x] = "B" if x >= BEAK_TIP_X else "O"
    # 3. eye
    for y in range(BH):
        for x in range(BW):
            if g[y][x] == "Y" and ell(x, y, ECX, ECY, ER, ER):
                g[y][x] = "W"
    for y in range(BH):
        for x in range(BW):
            if g[y][x] == "W" and ell(x, y, PCX, PCY, PR, PR):
                g[y][x] = "K"
    # 4. wing: orange ellipse with a black edge, clipped to the body
    wing = [[ell(x, y, WCX, wing_y, WRX, WRY) for x in range(BW)] for y in range(BH)]
    clipped = [[wing[y][x] and g[y][x] == "Y" for x in range(BW)] for y in range(BH)]
    for y in range(BH):
        for x in range(BW):
            if g[y][x] == "Y" and not clipped[y][x]:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < BW and 0 <= ny < BH and clipped[ny][nx]:
                            g[y][x] = "k"
                            break
    for y in range(BH):
        for x in range(BW):
            if clipped[y][x]:
                g[y][x] = "O"
    return ["".join(r) for r in g]

BIRD_FRAMES = [make_bird(3.6), make_bird(6.2), make_bird(8.8)]

CODE = {".": 0, "K": 1, "k": 1, "Y": 2, "O": 3, "W": 4, "B": 5}

# ----------------------------------------------------------------------------
# 3. 5x7 font
# ----------------------------------------------------------------------------
FONT = {
    " ": ["     "]*7,
    "A": [" ##  ", "#  # ", "#  # ", "#### ", "#  # ", "#  # ", "#  # "],
    "B": ["###  ", "#  # ", "#  # ", "###  ", "#  # ", "#  # ", "###  "],
    "C": [" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "],
    "D": ["###  ", "#  # ", "#   #", "#   #", "#   #", "#  # ", "###  "],
    "E": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
    "F": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "],
    "G": [" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ### "],
    "H": ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "I": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####"],
    "J": ["#####", "   # ", "   # ", "   # ", "#  # ", "#  # ", " ##  "],
    "K": ["#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"],
    "L": ["#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"],
    "M": ["#   #", "## ##", "# # #", "#   #", "#   #", "#   #", "#   #"],
    "N": ["#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"],
    "O": [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "P": ["#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "],
    "Q": [" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"],
    "R": ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
    "S": [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
    "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    "U": ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "V": ["#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "],
    "W": ["#   #", "#   #", "#   #", "#   #", "# # #", "## ##", "#   #"],
    "X": ["#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"],
    "Y": ["#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
    "Z": ["#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"],
    "0": [" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "],
    "1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    "2": [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
    "3": ["#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### "],
    "4": ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
    "5": ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
    "6": ["  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "],
    "7": ["#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "],
    "8": [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
    "9": [" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "],
}
GLYPH_ORDER = [" "] + [c for c in FONT if c != " "]
GLYPH_IDX = {c: i for i, c in enumerate(GLYPH_ORDER)}

# ----------------------------------------------------------------------------
# 4. Hill silhouette: 64 columns of 5-bit height (0..31)
# ----------------------------------------------------------------------------
HILLS = []
for i in range(64):
    h = 9 + 8.5 * math.sin(i * math.pi / 11.0) + 5.5 * math.sin(i * math.pi / 5.0 + 1.0)
    HILLS.append(max(0, min(31, int(round(h)))))

# ----------------------------------------------------------------------------
# emit
# ----------------------------------------------------------------------------
def pack_row(row, bpp):
    w = 0
    for ch in row:
        w = (w << bpp) | CODE[ch] if bpp == 3 else (w << bpp) | (1 if ch == "#" else 0)
    return w

out = []
A = out.append
A("// ============================================================================")
A("// gfx_roms.v - AUTO-GENERATED by gen_gfx.py.  DO NOT EDIT BY HAND.")
A("//")
A("//  * gfx_palette : 5-bit index -> BT.601 limited-range YCbCr.  The FPGA sends")
A("//                  YCbCr to the ADV7511, whose internal CSC converts back to RGB.")
A("//  * gfx_bird    : 16x12 bird sprite, 3 wing frames, 3 bits/pixel.")
A("//  * gfx_font    : 5x7 glyph ROM for the score and UI text.")
A("//  * gfx_hill    : 64 x 5-bit hill silhouette for the scrolling parallax band.")
A("// ============================================================================")
A("`timescale 1ns / 1ps")
A("")
A("// ----------------------------------------------------------------------------")
A("// Palette: index -> {Y, Cb, Cr}")
A("// ----------------------------------------------------------------------------")
A("module gfx_palette (")
A("    input  wire [4:0] idx,")
A("    output reg  [7:0] y,")
A("    output reg  [7:0] cb,")
A("    output reg  [7:0] cr")
A(");")
A("    always @* begin")
A("        case (idx)")
for i, (name, r, g, b) in enumerate(PAL):
    yi, cbi, cri = rgb_to_ycbcr601_limited(r, g, b)
    A("            5'd{:<2}: begin y = 8'd{:<3}; cb = 8'd{:<3}; cr = 8'd{:<3}; end // {:<9} #{:02X}{:02X}{:02X}".format(
        i, yi, cbi, cri, name, r, g, b))
A("            default: begin y = 8'd16; cb = 8'd128; cr = 8'd128; end")
A("        endcase")
A("    end")
A("endmodule")
A("")
A("// ----------------------------------------------------------------------------")
A("// Bird sprite: 3 frames x 12 rows x 16 pixels, 3 bits per pixel")
A("//   0=transparent 1=black outline 2=yellow body 3=orange wing")
A("//   4=white eye   5=dark-orange beak tip")
A("// ----------------------------------------------------------------------------")
A("module gfx_bird (")
A("    input  wire [1:0]  frame,")
A("    input  wire [3:0]  px,")
A("    input  wire [3:0]  py,")
A("    output reg  [2:0]  pix")
A(");")
A("    reg [47:0] rowbits;")
A("    always @* begin")
A("        case (frame)")
for fi, fr in enumerate(BIRD_FRAMES):
    A("            2'd{}: case (py) // frame {}".format(fi, fi))
    for ri, row in enumerate(fr):
        w = pack_row(row, 3)
        A("                4'd{:<2}: rowbits = 48'h{:012x}; // {}".format(ri, w, row))
    A("                default: rowbits = 48'h0;")
    A("            endcase")
A("        endcase")
A("        // 3 bits per pixel, pixel 0 is the most significant group")
A("        pix = rowbits[45 - px*3 +: 3];")
A("    end")
A("endmodule")
A("")
A("// ----------------------------------------------------------------------------")
A("// 5x7 glyph ROM: 5 columns x 7 rows, MSB of each row word = leftmost pixel")
A("// ----------------------------------------------------------------------------")
A("module gfx_font (")
A("    input  wire [5:0] glyph,")
A("    input  wire [2:0] px,")
A("    input  wire [2:0] py,")
A("    output reg        pix")
A(");")
A("    reg [4:0] rowbits;")
A("    always @* begin")
A("        case (glyph)")
for gi, ch in enumerate(GLYPH_ORDER):
    A("            6'd{:<2}: case (py) // '{}'".format(gi, ch if ch != " " else "space"))
    for ri, row in enumerate(FONT[ch]):
        w = pack_row(row, 1)
        A("                3'd{}: rowbits = 5'b{:05b};".format(ri, w))
    A("                default: rowbits = 5'b0;")
    A("            endcase")
A("        endcase")
A("        pix = rowbits[4 - px];")
A("    end")
A("endmodule")
A("")
A("// ----------------------------------------------------------------------------")
A("// Hill silhouette: 64 columns, 5-bit height (0..31), repeats horizontally")
A("// ----------------------------------------------------------------------------")
A("module gfx_hill (")
A("    input  wire [5:0] col,")
A("    output reg  [4:0] height")
A(");")
A("    always @* begin")
A("        case (col)")
for ci, h in enumerate(HILLS):
    A("            6'd{:<2}: height = 5'd{:<2};".format(ci, h))
A("            default: height = 5'd0;")
A("        endcase")
A("    end")
A("endmodule")
A("")
A("// ----------------------------------------------------------------------------")
A("// Text strings for the UI, addressed as (screen, line, character position).")
A("//   screen 0 = title screen,  screen 1 = game over screen")
A("//   line   0 = big top line,   line   1 = prompt line")
A("// ----------------------------------------------------------------------------")
TEXT = {
    (0, 0): "FLAPPY BIRD ",
    (0, 1): "PRESS SW5   ",
    (1, 0): "GAME OVER   ",
    (1, 1): "PRESS SW5   ",
}
A("module gfx_text (")
A("    input  wire       screen,")
A("    input  wire       line,")
A("    input  wire [3:0] idx,")
A("    output reg  [5:0] glyph")
A(");")
A("    reg [1:0] sel;")
A("    always @* begin")
A("        sel = {screen, line};")
A("        case (sel)")
for (sc, ln) in sorted(TEXT.keys()):
    s = TEXT[(sc, ln)]
    assert len(s) == 12, (sc, ln, s)
    A("            2'b{}{}: case (idx) // \"{}\"".format(sc, ln, s))
    for i, ch in enumerate(s):
        A("                4'd{:<2}: glyph = 6'd{:<2}; // '{}'".format(i, GLYPH_IDX[ch], ch))
    A("                default: glyph = 6'd0;")
    A("            endcase")
A("        endcase")
A("    end")
A("endmodule")
A("")
A("// Glyph indices (6-bit): " + " ".join("{}={}".format(c if c != " " else "' '", GLYPH_IDX[c]) for c in GLYPH_ORDER))
A("// (digits 0-9 are glyph {:d}..{:d}, i.e. 6'd27 + digit)".format(GLYPH_IDX["0"], GLYPH_IDX["9"]))
A("")

with open("gfx_roms.v", "w") as f:
    f.write("\n".join(out) + "\n")

# ----------------------------------------------------------------------------
# report
# ----------------------------------------------------------------------------
print("Palette (idx name RGB -> Y,Cb,Cr):")
for i, (name, r, g, b) in enumerate(PAL[:24]):
    yi, cbi, cri = rgb_to_ycbcr601_limited(r, g, b)
    print("  {:2d} {:<9} #{:02X}{:02X}{:02X} -> Y={:3d} Cb={:3d} Cr={:3d}".format(i, name, r, g, b, yi, cbi, cri))
print()
for fi, fr in enumerate(BIRD_FRAMES):
    print("Bird frame {}:  ('.'=transp K=black Y=yellow O=orange W=white B=beak-shade)".format(fi))
    for r in fr:
        print("   " + r)
    print()
print("Glyphs:", GLYPH_ORDER)
print("Hills :", HILLS)
print("\nwrote gfx_roms.v")
