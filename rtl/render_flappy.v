// ============================================================================
//  render_flappy.v -- purely combinational pixel generator for 640x480.
//
//  Consumes the current beam position (x,y) and the game state, and produces
//  a 5-bit palette index.  The palette (gfx_palette) turns that into YCbCr.
//
//  Layer order, front to back:
//      bird > UI text > score > pipes > clouds > hills > ground > sky
//
//  Fixed screen layout (640x480):
//      bird    16x12 sprite at x=96, y=bird_y
//      pipes   64 px wide, 140 px gap, at pipe_x0..2
//      ground  y >= 400 (grass 400..407, edge 408..410, dirt 411..479)
//      score   3 digits, scale 3, top centre (y = 28)
//      text    2 lines of 12 glyphs, scale 3 (y = 120 and y = 210)
// ============================================================================
`timescale 1ns / 1ps

module render_flappy (
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    // game state
    input  wire [1:0]  state,
    input  wire [9:0]  bird_y,
    input  wire [1:0]  bird_frame,
    input  wire [3:0]  score_h, score_t, score_o,
    input  wire [3:0]  hi_h, hi_t, hi_o,
    input  wire        show_score,
    input  wire [9:0]  pipe_x0, pipe_x1, pipe_x2,
    input  wire [9:0]  gap0, gap1, gap2,
    input  wire [9:0]  scroll,
    // output palette index
    output reg  [4:0]  pidx
);

    // ------------------------------------------------------------- palette ids
    localparam P_SKY0=5'd0, P_SKY1=5'd1, P_SKY2=5'd2, P_CLOUD=5'd3,
               P_HILL_LT=5'd4, P_HILL_DK=5'd5,
               P_GRASS=5'd8, P_GRASS_DK=5'd9, P_SAND=5'd10, P_SAND_DK=5'd11,
               P_PIPE=5'd12, P_PIPE_HI=5'd13, P_PIPE_DK=5'd14,
               P_BIRD_Y=5'd15, P_BIRD_O=5'd16, P_WHITE=5'd17, P_BLACK=5'd18,
               P_TXT=5'd19, P_GO_RED=5'd21, P_BEAK_DK=5'd22, P_GROUND_E=5'd23;

    localparam S_IDLE = 2'd0, S_PLAY = 2'd1, S_FALL = 2'd2, S_OVER = 2'd3;

    // geometry
    localparam [9:0] GROUND_Y = 10'd400;
    localparam [9:0] BIRD_X   = 10'd96;
    localparam [9:0] PIPE_W   = 10'd64;
    localparam [9:0] GAP_H    = 10'd140;
    localparam [9:0] SC_X0    = 10'd291;   // score digits
    localparam [9:0] SC_Y0    = 10'd28;
    localparam [9:0] TX_X0    = 10'd213;   // text lines
    localparam [9:0] TX_Y0    = 10'd120;
    localparam [9:0] TX_Y1    = 10'd210;

    reg [4:0] bg_c;
    wire [9:0] sx = x + scroll;            // scrolling coordinate for the ground

    // ---------------------------------------------------------------- 1. sky
    always @* begin
        if (y >= GROUND_Y) begin
            if (y < 10'd408)      bg_c = sx[3] ? P_GRASS : P_GRASS_DK;
            else if (y < 10'd411) bg_c = P_GROUND_E;
            else                  bg_c = (y[3:2] == 2'b00) ? P_SAND_DK :
                                         ((sx[3] ^ y[2]) ? P_SAND : P_SAND_DK);
        end else begin
            if (y < 10'd100)      bg_c = (y[3] ^ x[4]) ? P_SKY0 : P_SKY1;
            else if (y < 10'd240) bg_c = P_SKY1;
            else                  bg_c = (x[4] ^ y[4]) ? P_SKY1 : P_SKY2;
        end
    end

    // -------------------------------------------------------------- 2. hills
    wire [10:0] hsum = {1'b0, x} + {2'b00, scroll[9:1]};   // half-speed parallax
    wire [5:0]  hcol = hsum[5:0];
    wire [4:0]  hh;
    gfx_hill u_hill (.col(hcol), .height(hh));
    wire [9:0]  hill_top = GROUND_Y - {5'b0, hh};
    wire        hill_on = (y >= hill_top) && (y < GROUND_Y);
    wire [4:0]  hill_c  = (y < (hill_top + 10'd3)) ? P_HILL_LT : P_HILL_DK;

    // ------------------------------------------------------------- 3. clouds
    //  three puffy clouds, quarter-speed parallax, wrapping in a 768 px cycle
    localparam [9:0] CL0_X = 10'd120, CL1_X = 10'd430, CL2_X = 10'd690;
    localparam [9:0] CL0_Y = 10'd44,  CL1_Y = 10'd104, CL2_Y = 10'd196;

    function [9:0] cloud_pos;              // (base - offset) mod 768
        input [9:0] base;
        input [7:0] off;
        reg [10:0] v;
        begin
            v = {1'b0, base} + 11'd768 - {3'b000, off};
            cloud_pos = (v >= 11'd768) ? (v[9:0] - 10'd768) : v[9:0];
        end
    endfunction

    // NOTE: the pixel coordinates are passed in as arguments instead of being
    // read from the module inputs.  A function that reads module signals hides
    // those dependencies from the continuous assignment that calls it, so the
    // wire is only re-evaluated when its *arguments* change -- with x/y hidden
    // inside the body the test was computed once at time 0 and never again.
    function cloud_hit;                    // 48x16 box with cut corners
        input [9:0] xx;
        input [9:0] yy;
        input [9:0] cx;
        input [9:0] cy;
        reg [9:0] dx, dy;
        begin
            dx = xx - cx;
            dy = yy - cy;
            cloud_hit = ({1'b0,xx} >= {1'b0,cx}) && ({1'b0,xx} < ({1'b0,cx} + 11'd48)) &&
                        ({1'b0,yy} >= {1'b0,cy}) && ({1'b0,yy} < ({1'b0,cy} + 11'd16)) &&
                        !(((dx < 10'd6) || (dx > 10'd41)) &&
                          ((dy < 10'd4) || (dy > 10'd11)));
        end
    endfunction

    wire [9:0] coff = {2'b00, scroll[9:2]};
    wire [9:0] cl0x = cloud_pos(CL0_X, scroll[9:2]);
    wire [9:0] cl1x = cloud_pos(CL1_X, scroll[9:2]);
    wire [9:0] cl2x = cloud_pos(CL2_X, scroll[9:2]);
    wire c0_on = cloud_hit(x, y, cl0x, CL0_Y);
    wire c1_on = cloud_hit(x, y, cl1x, CL1_Y);
    wire c2_on = cloud_hit(x, y, cl2x, CL2_Y);

    // -------------------------------------------------------------- 4. pipes
    function [4:0] pipe_col;
        input [9:0] dx;        // x - pipe left edge
        input [9:0] gp;        // gap top edge
        input [9:0] yy;
        reg         cap, cap_edge;
        begin
            cap      = ((yy + 10'd16) >= gp) && (yy < gp);                     // above the gap
            cap_edge = cap && ((yy + 10'd3) >= gp);
            if (yy >= (gp + GAP_H)) begin                                     // below the gap
                cap      = (yy < (gp + GAP_H + 10'd16));
                cap_edge = cap && (yy < (gp + GAP_H + 10'd3));
            end
            if ((dx < 10'd2) || (dx >= (PIPE_W - 10'd2)))
                pipe_col = P_PIPE_DK;                                         // sides
            else if (cap_edge)
                pipe_col = P_PIPE_DK;                                         // cap lip
            else if ((dx >= 10'd4) && (dx < 10'd10))
                pipe_col = P_PIPE_HI;                                         // highlight
            else
                pipe_col = P_PIPE;
        end
    endfunction

    // upper pipe column test: inside the 64 px column, above or below the gap
    // (x/y are arguments here for the same reason as in cloud_hit above)
    function pipe_on;
        input [9:0] xx;
        input [9:0] yy;
        input [9:0] pxc;
        input [9:0] gp;
        begin
            pipe_on = ({1'b0,xx} >= {1'b0,pxc}) && ({1'b0,xx} < ({1'b0,pxc} + 11'd64)) &&
                      (yy < GROUND_Y) &&
                      (({1'b0,yy} < {1'b0,gp}) || ({1'b0,yy} >= ({1'b0,gp} + {1'b0,GAP_H})));
        end
    endfunction

    wire        p0_on = pipe_on(x, y, pipe_x0, gap0);
    wire [4:0]  p0_c  = pipe_col(x - pipe_x0, gap0, y);
    wire        p1_on = pipe_on(x, y, pipe_x1, gap1);
    wire [4:0]  p1_c  = pipe_col(x - pipe_x1, gap1, y);
    wire        p2_on = pipe_on(x, y, pipe_x2, gap2);
    wire [4:0]  p2_c  = pipe_col(x - pipe_x2, gap2, y);

    // ---------------------------------------------------------- 5. UI text
    // 12 glyph cells of 18 px, glyphs are 15x21 (5x7 font at scale 3)
    function [2:0] div3;
        input [9:0] v;
        begin
            div3 = (v >= 10'd18) ? 3'd6 : (v >= 10'd15) ? 3'd5 : (v >= 10'd12) ? 3'd4 :
                   (v >= 10'd9)  ? 3'd3 : (v >= 10'd6)  ? 3'd2 : (v >= 10'd3)  ? 3'd1 : 3'd0;
        end
    endfunction

    function [3:0] cell18;
        input [9:0] v;
        begin
            cell18 = (v >= 10'd198) ? 4'd11 : (v >= 10'd180) ? 4'd10 :
                     (v >= 10'd162) ? 4'd9  : (v >= 10'd144) ? 4'd8  :
                     (v >= 10'd126) ? 4'd7  : (v >= 10'd108) ? 4'd6  :
                     (v >= 10'd90)  ? 4'd5  : (v >= 10'd72)  ? 4'd4  :
                     (v >= 10'd54)  ? 4'd3  : (v >= 10'd36)  ? 4'd2  :
                     (v >= 10'd18)  ? 4'd1  : 4'd0;
        end
    endfunction

    wire        txt_scr  = (state == S_OVER);        // 1 = game over screen
    wire        txt_act  = (state == S_IDLE) || (state == S_OVER);
    wire        t_line   = (y >= TX_Y1);
    wire        t_v      = ((y >= TX_Y0) && (y < (TX_Y0 + 10'd21))) ||
                           ((y >= TX_Y1) && (y < (TX_Y1 + 10'd21)));
    wire        t_h      = ({1'b0,x} >= {1'b0,TX_X0}) &&
                           ({1'b0,x} < ({1'b0,TX_X0} + 11'd216));
    wire [9:0]  tdx      = x - TX_X0;
    wire [3:0]  t_idx    = cell18(tdx);
    wire [9:0]  t_off    = {t_idx, 4'b0} + {t_idx, 1'b0};   // idx * 18
    wire [9:0]  t_tx     = tdx - t_off;
    wire [9:0]  tdy      = t_line ? (y - TX_Y1) : (y - TX_Y0);
    wire [2:0]  t_col    = div3(t_tx);
    wire [2:0]  t_row    = div3(tdy);
    wire        t_cell   = (t_tx < 10'd15) && (t_col <= 3'd4);

    wire [5:0]  t_glyph;
    gfx_text u_text (.screen(txt_scr), .line(t_line), .idx(t_idx), .glyph(t_glyph));
    wire        t_pix;
    gfx_font u_font_txt (.glyph(t_glyph), .px(t_col), .py(t_row), .pix(t_pix));

    wire        t_on = txt_act && t_v && t_h && t_cell && t_pix;
    wire [4:0]  t_c  = (txt_scr && !t_line) ? P_GO_RED : P_TXT;

    // ------------------------------------------------------------- 6. score
    wire        sc_v    = (y >= SC_Y0) && (y < (SC_Y0 + 10'd21));
    wire        sc_h    = ({1'b0,x} >= {1'b0,SC_X0}) &&
                          ({1'b0,x} < ({1'b0,SC_X0} + 11'd63));
    wire [9:0]  sdx     = x - SC_X0;
    wire [1:0]  sc_sel  = (sdx >= 10'd42) ? 2'd2 : (sdx >= 10'd21) ? 2'd1 : 2'd0;
    wire [9:0]  sc_off  = (sc_sel == 2'd0) ? 10'd0 : (sc_sel == 2'd1) ? 10'd21 : 10'd42;
    wire [9:0]  sc_tx   = sdx - sc_off;
    wire [2:0]  sc_col  = div3(sc_tx);
    wire [2:0]  sc_row  = div3(y - SC_Y0);
    wire [3:0]  sc_dig  = (sc_sel == 2'd0) ? score_h :
                          (sc_sel == 2'd1) ? score_t : score_o;
    wire [5:0]  sc_glyph = 6'd27 + {2'b00, sc_dig};    // glyph 27 = '0'
    wire        sc_pix;
    gfx_font u_font_score (.glyph(sc_glyph), .px(sc_col), .py(sc_row), .pix(sc_pix));
    wire        sc_on = show_score && sc_v && sc_h && (sc_tx < 10'd15) && (sc_col <= 3'd4);

    // -------------------------------------------------------------- 7. bird
    wire [9:0]  bdx  = x - BIRD_X;
    wire [9:0]  bdy  = y - bird_y;
    wire        b_on = ({1'b0,x} >= {1'b0,BIRD_X}) && ({1'b0,x} < ({1'b0,BIRD_X} + 11'd16)) &&
                       ({1'b0,y} >= {1'b0,bird_y}) && ({1'b0,y} < ({1'b0,bird_y} + 11'd12));
    wire [2:0]  b_pix;
    gfx_bird u_bird (.frame(bird_frame), .px(bdx[3:0]), .py(bdy[3:0]), .pix(b_pix));
    wire        b_lit = b_on && (b_pix != 3'd0);
    wire [4:0]  b_c = (b_pix == 3'd1) ? P_BLACK  : (b_pix == 3'd2) ? P_BIRD_Y :
                      (b_pix == 3'd3) ? P_BIRD_O : (b_pix == 3'd4) ? P_WHITE : P_BEAK_DK;

    // ---------------------------------------------------------- 8. high score
    //  "HI nnn" on the title and game-over screens, using the same 21-px cell
    //  metrics as the score row so its digits sit directly above the score's.
    //  Labels occupy three cells (H, I, space), then the three best digits.
    localparam [9:0] HI_X0 = 10'd228;
    localparam [9:0] HI_Y0 = 10'd270;

    wire        hi_v     = (y >= HI_Y0) && (y < (HI_Y0 + 10'd21));
    wire [9:0]  hidx     = x - HI_X0;
    wire [2:0]  hi_sel   = (hidx >= 10'd105) ? 3'd5 : (hidx >= 10'd84) ? 3'd4 :
                           (hidx >= 10'd63)  ? 3'd3 : (hidx >= 10'd42) ? 3'd2 :
                           (hidx >= 10'd21)  ? 3'd1 : 3'd0;
    // cell offset = hi_sel * 21, as a shift-add instead of a DSP multiply: this
    // sits on the same pixel path as the renderer and a multiply costs ~2.8 ns
    wire [9:0]  hi_off   = {3'b0, hi_sel, 4'b0} + {3'b0, hi_sel, 2'b0} + {7'b0, hi_sel};
    wire [9:0]  hi_tx    = hidx - hi_off;
    wire [2:0]  hi_col   = div3(hi_tx);
    wire [2:0]  hi_row   = div3(y - HI_Y0);
    wire [5:0]  hi_glyph = (hi_sel == 3'd0) ? 6'd8 :                     // 'H'
                           (hi_sel == 3'd1) ? 6'd9 :                     // 'I'
                           (hi_sel == 3'd2) ? 6'd0 :                     // ' '
                           (hi_sel == 3'd3) ? (6'd27 + {2'b00, hi_h}) :
                           (hi_sel == 3'd4) ? (6'd27 + {2'b00, hi_t}) :
                                              (6'd27 + {2'b00, hi_o});
    wire        hi_pix;
    gfx_font u_font_hi (.glyph(hi_glyph), .px(hi_col), .py(hi_row), .pix(hi_pix));
    wire        hi_on = txt_act && hi_v && (hidx < 10'd126) &&
                        (hi_tx < 10'd15) && (hi_col <= 3'd4);

    // ------------------------------------------------------------ priority
    always @* begin
        if      (b_lit)     pidx = b_c;
        else if (t_on)      pidx = t_c;
        else if (sc_on && sc_pix) pidx = P_TXT;
        else if (hi_on && hi_pix) pidx = P_TXT;
        else if (p0_on)     pidx = p0_c;
        else if (p1_on)     pidx = p1_c;
        else if (p2_on)     pidx = p2_c;
        else if (c0_on || c1_on || c2_on) pidx = P_CLOUD;
        else if (hill_on)   pidx = hill_c;
        else                pidx = bg_c;
    end

endmodule
