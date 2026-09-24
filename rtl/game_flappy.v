// ============================================================================
//  game_flappy.v -- "Flappy Bird" game logic, bare RTL, no processor.
//
//  All movement is integer pixel based, one update per video frame
//  (59.5 Hz), which gives the chunky arcade feel of an 8-bit console game.
//
//  States:  0 = IDLE (title, bird bobbing)   1 = PLAY
//           2 = FALL (dead, bird dropping)   3 = OVER (game over screen)
//
//  World layout (640x480):
//      bird    : fixed x = 96, 16x12 sprite box, bird_y = top edge
//      pipes   : 3 pipes, 64 px wide, 140 px gap, evenly spaced in a 960 px
//                cycle (spacing 320), scrolling left 2 px per frame
//      ground  : y >= 400
// ============================================================================
`timescale 1ns / 1ps

module game_flappy (
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,        // one-cycle pulse at the end of every frame
    input  wire        flap,        // debounced SW5 press pulse
    // ---- renderer interface ----
    output reg  [1:0]  state,
    output reg  [9:0]  bird_y,      // top of the 16x12 sprite box
    output reg  [1:0]  bird_frame,  // wing animation frame
    output reg  [3:0]  score_h,     // hundreds
    output reg  [3:0]  score_t,     // tens
    output reg  [3:0]  score_o,     // ones
    output reg  [3:0]  hi_h,        // best score this power session, hundreds
    output reg  [3:0]  hi_t,        // ... tens
    output reg  [3:0]  hi_o,        // ... ones
    output wire        show_score,
    output reg  [9:0]  pipe_x0, pipe_x1, pipe_x2,   // left edge, 0..959
    output reg  [9:0]  gap0, gap1, gap2,            // gap top edge
    output reg  [9:0]  scroll       // free-running scroll phase (background)
);

    // ---------------------------------------------------------------- geometry
    localparam BIRD_X    = 10'd96;
    localparam BIRD_L    = 10'd98;         // collision box (inset into the sprite)
    localparam BIRD_R    = 10'd108;
    localparam GROUND_Y  = 10'd400;
    localparam PIPE_W    = 10'd64;
    localparam GAP_H     = 10'd140;
    localparam SPEED     = 10'd2;
    localparam CYCLE     = 10'd960;        // 3 * 320
    localparam BIRD_Y_MIN = 10'd0;
    localparam BIRD_Y_MAX = 10'd388;       // 388 + 12 = 400 = ground

    // ------------------------------------------------------------------ states
    localparam S_IDLE = 2'd0, S_PLAY = 2'd1, S_FALL = 2'd2, S_OVER = 2'd3;

    // ------------------------------------------------------------- game state
    reg signed [10:0] vy;                  // vertical velocity, px per frame
    localparam signed [10:0] FLAP_VY = -11'sd7;
    localparam signed [10:0] MAX_VY  =  11'sd8;

    reg  [3:0]  anim_cnt;
    reg  [3:0]  bob_cnt;
    reg  [15:0] rng;
    reg  [2:0]  scored;                    // per pipe "already counted" flags

    wire [2:0]  bob = bob_cnt[3] ? ~bob_cnt[2:0] : bob_cnt[2:0];

    assign show_score = (state != S_IDLE);

    // ------------------------------------------------------------------------
    // next-frame values (combinational)
    // ------------------------------------------------------------------------
    // pipe positions
    wire        w0 = (pipe_x0 < SPEED);
    wire        w1 = (pipe_x1 < SPEED);
    wire        w2 = (pipe_x2 < SPEED);
    wire [9:0]  p0_nxt = w0 ? (pipe_x0 + (CYCLE - SPEED)) : (pipe_x0 - SPEED);
    wire [9:0]  p1_nxt = w1 ? (pipe_x1 + (CYCLE - SPEED)) : (pipe_x1 - SPEED);
    wire [9:0]  p2_nxt = w2 ? (pipe_x2 + (CYCLE - SPEED)) : (pipe_x2 - SPEED);

    // new random gap on wrap: 60 .. 246 in steps of 6
    wire [4:0]  rnd5   = rng[9:5];
    wire [9:0]  rnd_gap = 10'd60 + {rnd5, 2'b00} + {rnd5, 1'b0};

    // physics -- the button only does anything while the game is running
    wire flap_ok = flap && (state == S_PLAY);
    wire signed [10:0] vy_nxt = flap_ok ? FLAP_VY :
                                ((vy >= MAX_VY) ? MAX_VY : (vy + 11'sd1));
    // NOTE: the cast to signed is essential -- mixing an unsigned operand into
    // the sum would make Verilog evaluate the whole expression as unsigned, so
    // a negative velocity would wrap into a huge positive number.
    wire signed [11:0] y_raw  = $signed({1'b0, bird_y}) + vy_nxt;
    wire        hit_ground = (y_raw > {1'b0, BIRD_Y_MAX});
    wire [9:0]  y_nxt = hit_ground      ? BIRD_Y_MAX :
                        (y_raw < 0)     ? BIRD_Y_MIN : y_raw[9:0];

    // collision with pipes
    wire [10:0] p0_r = {1'b0, pipe_x0} + {1'b0, PIPE_W};
    wire [10:0] p1_r = {1'b0, pipe_x1} + {1'b0, PIPE_W};
    wire [10:0] p2_r = {1'b0, pipe_x2} + {1'b0, PIPE_W};
    wire [10:0] bl   = {1'b0, BIRD_L};
    wire [10:0] br   = {1'b0, BIRD_R};

    wire [9:0]  b_top = bird_y + 10'd2;
    wire [9:0]  b_bot = bird_y + 10'd9;
    wire [10:0] gap_bot0 = {1'b0, gap0} + {1'b0, GAP_H};
    wire [10:0] gap_bot1 = {1'b0, gap1} + {1'b0, GAP_H};
    wire [10:0] gap_bot2 = {1'b0, gap2} + {1'b0, GAP_H};

    wire x_over0 = ({1'b0, pipe_x0} < br) && (p0_r > bl);
    wire x_over1 = ({1'b0, pipe_x1} < br) && (p1_r > bl);
    wire x_over2 = ({1'b0, pipe_x2} < br) && (p2_r > bl);

    wire hit0 = x_over0 && (({1'b0, b_top} < {1'b0, gap0}) || ({1'b0, b_bot} > gap_bot0));
    wire hit1 = x_over1 && (({1'b0, b_top} < {1'b0, gap1}) || ({1'b0, b_bot} > gap_bot1));
    wire hit2 = x_over2 && (({1'b0, b_top} < {1'b0, gap2}) || ({1'b0, b_bot} > gap_bot2));

    wire dead = (state == S_PLAY) && (hit0 || hit1 || hit2 || hit_ground);

    // scoring: a pipe has been passed when its right edge is left of the bird
    wire pass0 = !scored[0] && (p0_r < bl);
    wire pass1 = !scored[1] && (p1_r < bl);
    wire pass2 = !scored[2] && (p2_r < bl);
    wire pass  = pass0 || pass1 || pass2;   // at most one pipe can pass per frame

    // ------------------------------------------------------------- high score
    // The next score value is computed combinationally, then compared against
    // the stored best.  The high score is deliberately NOT cleared by the
    // start/restart paths -- it only ever moves up, so it survives every game
    // restart and is lost only on power-off or bitstream reload.
    wire [3:0] so_nxt = !pass ? score_o :
                        (score_o == 4'd9) ? 4'd0 : (score_o + 4'd1);
    wire       ct     = pass && (score_o == 4'd9);
    wire [3:0] st_nxt = !ct ? score_t :
                        (score_t == 4'd9) ? 4'd0 : (score_t + 4'd1);
    wire       ch     = ct && (score_t == 4'd9);
    wire [3:0] sh_nxt = (ch && (score_h != 4'd9)) ? (score_h + 4'd1) : score_h;

    wire [11:0] score_nxt = {sh_nxt, st_nxt, so_nxt};
    wire [11:0] hi_cur    = {hi_h, hi_t, hi_o};
    wire [11:0] hi_nxt    = (score_nxt > hi_cur) ? score_nxt : hi_cur;

    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            bird_y      <= 10'd200;
            bird_frame  <= 2'd0;
            vy          <= 11'sd0;
            score_h     <= 4'd0;
            score_t     <= 4'd0;
            score_o     <= 4'd0;
            hi_h        <= 4'd0;
            hi_t        <= 4'd0;
            hi_o        <= 4'd0;
            pipe_x0     <= 10'd250;
            pipe_x1     <= 10'd570;
            pipe_x2     <= 10'd890;
            gap0        <= 10'd90;
            gap1        <= 10'd150;
            gap2        <= 10'd120;
            scroll      <= 10'd0;
            anim_cnt    <= 4'd0;
            bob_cnt     <= 4'd0;
            rng         <= 16'hACE1;
            scored      <= 3'b111;
        end else begin
            // free-running LFSR for pipe gap positions
            if (tick)
                rng <= {rng[14:0], rng[15] ^ rng[13] ^ rng[12] ^ rng[10]};

            // background scroll always runs (also on the title screen)
            if (tick)
                scroll <= scroll + 10'd1;

            case (state)
            // ------------------------------------------------------------------
            S_IDLE: begin
                if (tick) begin
                    bob_cnt  <= bob_cnt + 4'd1;
                    anim_cnt <= anim_cnt + 4'd1;
                    if (anim_cnt[3]) bird_frame <= 2'd0;
                    else if (anim_cnt[2]) bird_frame <= 2'd1;
                    else bird_frame <= 2'd2;
                    bird_y <= 10'd200 + {7'b0, bob};
                end
                if (flap) begin          // start a new game
                    state      <= S_PLAY;
                    bird_y     <= 10'd200;
                    vy         <= 11'sd0;
                    bird_frame <= 2'd0;
                    score_h    <= 4'd0;
                    score_t    <= 4'd0;
                    score_o    <= 4'd0;
                    pipe_x0    <= 10'd250;
                    pipe_x1    <= 10'd570;
                    pipe_x2    <= 10'd890;
                    gap0       <= 10'd90;
                    gap1       <= 10'd150;
                    gap2       <= 10'd120;
                    scored     <= 3'b000;
                    anim_cnt   <= 4'd0;
                end
            end
            // ------------------------------------------------------------------
            S_PLAY: begin
                if (tick) begin
                    // ---- bird ----
                    bird_y <= y_nxt;
                    vy     <= vy_nxt;
                    if (anim_cnt == 4'd5) begin
                        anim_cnt   <= 4'd0;
                        // 3 sprite frames exist -> cycle 0,1,2,0,1,2...
                        bird_frame <= (bird_frame == 2'd2) ? 2'd0 : (bird_frame + 2'd1);
                    end else begin
                        anim_cnt <= anim_cnt + 4'd1;
                    end

                    // ---- pipes ----
                    pipe_x0 <= p0_nxt;
                    pipe_x1 <= p1_nxt;
                    pipe_x2 <= p2_nxt;
                    if (w0) gap0 <= rnd_gap;
                    if (w1) gap1 <= rnd_gap;
                    if (w2) gap2 <= rnd_gap;

                    // ---- scoring + high score ----
                    if (pass) begin
                        score_o <= so_nxt;
                        score_t <= st_nxt;
                        score_h <= sh_nxt;
                        hi_h    <= hi_nxt[11:8];
                        hi_t    <= hi_nxt[7:4];
                        hi_o    <= hi_nxt[3:0];
                    end
                    if (pass0) scored[0] <= 1'b1;
                    if (pass1) scored[1] <= 1'b1;
                    if (pass2) scored[2] <= 1'b1;
                    if (w0) scored[0] <= 1'b0;
                    if (w1) scored[1] <= 1'b0;
                    if (w2) scored[2] <= 1'b0;
                end

                if (flap && !dead) begin        // a flap overrides the velocity
                    vy <= FLAP_VY;
                end

                if (dead)
                    state <= S_FALL;
            end
            // ------------------------------------------------------------------
            S_FALL: begin
                if (tick) begin
                    bird_y <= y_nxt;
                    vy     <= vy_nxt;           // keeps falling, no control
                    if (bird_y >= BIRD_Y_MAX - 10'd1)
                        state <= S_OVER;
                end
            end
            // ------------------------------------------------------------------
            S_OVER: begin
                if (flap) begin
                    state      <= S_PLAY;
                    bird_y     <= 10'd200;
                    vy         <= 11'sd0;
                    bird_frame <= 2'd0;
                    score_h    <= 4'd0;
                    score_t    <= 4'd0;
                    score_o    <= 4'd0;
                    pipe_x0    <= 10'd250;
                    pipe_x1    <= 10'd570;
                    pipe_x2    <= 10'd890;
                    gap0       <= 10'd90;
                    gap1       <= 10'd150;
                    gap2       <= 10'd120;
                    scored     <= 3'b000;
                    anim_cnt   <= 4'd0;
                end
            end
            // ------------------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
