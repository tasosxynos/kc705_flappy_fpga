// ============================================================================
//  tb_flappy_system.v -- simulation harness for the whole video/game pipeline.
//
//  Instantiates the real RTL (video_timing + game_flappy + render_flappy +
//  gfx_palette + ycbcr422_pack) and then:
//
//    * measures the 640x480 timing (clocks per frame, lines per frame, active
//      pixels/lines, sync widths) and fails if it is not exactly right,
//    * checks the 16-bit 4:2:2 packing (chroma in the high byte, luma in the
//      low byte, the two pixels of a pair sharing one chroma sample),
//    * flies the bird with a small autopilot so the game is actually played and
//      the scoring path is exercised,
//    * ends the game twice -- once by letting the bird hit the ground and once
//      by forcing a pipe onto it -- to exercise both death paths,
//    * writes three full RGB frames as PPM images -- the RGB is reconstructed
//      with the inverse of the ADV7511 colour-space conversion, so these are
//      what actually appears on a monitor.
//
//  Timeline (video frames, 59.5 Hz):
//      2       title screen                        -> frame_title.ppm
//      3       flap: game starts, no more input, the bird falls
//      ~31     bird hits the ground -> FALL -> OVER
//      34      game over screen                    -> frame_over.ppm
//      40      flap: game restarts
//      41-174  autopilot keeps the bird flying, it passes the first pipe
//      155     gameplay, score 001                 -> frame_play.ppm
//      175     white-box test: force a pipe onto the bird
//      ~178    expect game over from the pipe collision
//      210     checks and finish
//
//  Run with:   xsim tb_flappy_system -R
// ============================================================================
`timescale 1ns / 1ps

module tb_flappy_system;

    // ---------------------------------------------------------------- clock
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;                  // 25 MHz

    // ------------------------------------------------------------- pipeline
    wire [9:0] hcnt, vcnt;
    wire       de, hs_n, vs_n, tick;
    video_timing u_tim (
        .clk(clk), .rst(rst),
        .hcnt(hcnt), .vcnt(vcnt),
        .hsync_n(hs_n), .vsync_n(vs_n),
        .de(de), .frame_tick(tick)
    );

    reg  flap = 1'b0;
    wire [1:0] state, bird_frame;
    wire [9:0] bird_y, px0, px1, px2, gap0, gap1, gap2, scroll;
    wire [3:0] score_h, score_t, score_o;
    wire       show_score;

    game_flappy u_game (
        .clk(clk), .rst(rst), .tick(tick), .flap(flap),
        .state(state), .bird_y(bird_y), .bird_frame(bird_frame),
        .score_h(score_h), .score_t(score_t), .score_o(score_o),
        .show_score(show_score),
        .pipe_x0(px0), .pipe_x1(px1), .pipe_x2(px2),
        .gap0(gap0), .gap1(gap1), .gap2(gap2),
        .scroll(scroll)
    );

    wire [4:0] pidx;
    render_flappy u_rend (
        .x(hcnt), .y(vcnt),
        .state(state), .bird_y(bird_y), .bird_frame(bird_frame),
        .score_h(score_h), .score_t(score_t), .score_o(score_o),
        .show_score(show_score),
        .pipe_x0(px0), .pipe_x1(px1), .pipe_x2(px2),
        .gap0(gap0), .gap1(gap1), .gap2(gap2),
        .scroll(scroll),
        .pidx(pidx)
    );

    wire [7:0] py, pcb, pcr;
    gfx_palette u_pal (.idx(pidx), .y(py), .cb(pcb), .cr(pcr));

    wire [15:0] vid_d;
    wire        vid_de, vid_hs, vid_vs;
    ycbcr422_pack u_pack (
        .clk(clk), .rst(rst),
        .de(de), .hsync_n(hs_n), .vsync_n(vs_n), .hcnt(hcnt),
        .pix_y(py), .pix_cb(pcb), .pix_cr(pcr),
        .vid_d(vid_d), .vid_de(vid_de), .vid_hs(vid_hs), .vid_vs(vid_vs)
    );

    // ------------------------------------------------------------ bookkeeping
    integer frame  = 0;
    integer errors = 0;

    reg [8*8-1:0] sname;
    always @* begin
        case (state)
        2'd0: sname = "IDLE";
        2'd1: sname = "PLAY";
        2'd2: sname = "FALL";
        2'd3: sname = "OVER";
        default: sname = "??";
        endcase
    end

    // counters, all reset at every frame start so we can measure one frame
    integer clkc = 0, linesc = 0, pixc = 0, alinesc = 0, hslow = 0, vslow = 0;
    integer m_clk = 0, m_lines = 0, m_pix = 0, m_alines = 0, m_hslow = 0, m_vslow = 0;

    always @(posedge clk) begin
        if (!rst) begin
            clkc    = clkc + 1;
            if (hcnt == 10'd799)      linesc = linesc + 1;
            if (de)                   pixc   = pixc + 1;
            // de is registered, so the first active pixel of a line is the one
            // seen while hcnt == 1
            if (de && hcnt == 10'd1)  alinesc = alinesc + 1;
            if (!hs_n)                hslow  = hslow + 1;
            if (!vs_n)                vslow  = vslow + 1;

            if (tick) begin
                // one frame just completed -> snapshot it
                m_clk    = clkc;     m_lines  = linesc;  m_pix = pixc;
                m_alines = alinesc;  m_hslow  = hslow;   m_vslow = vslow;

                if (frame == 2) begin
                    $display("--- measured 640x480 timing (one frame) ---");
                    $display("clocks/frame     = %0d  (expect 420000)", m_clk);
                    $display("lines/frame      = %0d  (expect 525)",    m_lines);
                    $display("active pixels    = %0d  (expect 307200)", m_pix);
                    $display("active lines     = %0d  (expect 480)",    m_alines);
                    $display("hsync low clocks = %0d  (expect 50400 = 96 * 525)", m_hslow);
                    $display("vsync low clocks = %0d  (expect 1600 = 2 lines * 800)", m_vslow);
                    $display("frame rate       = %0.3f Hz",
                             25000000.0 / (m_clk + 1));
                    if (m_clk    != 420000) begin errors = errors + 1; $display("ERROR: clocks/frame"); end
                    if (m_lines  != 525)    begin errors = errors + 1; $display("ERROR: lines/frame");  end
                    if (m_pix    != 307200) begin errors = errors + 1; $display("ERROR: active pixels");end
                    if (m_alines != 480)    begin errors = errors + 1; $display("ERROR: active lines"); end
                    if (m_hslow  != 50400)  begin errors = errors + 1; $display("ERROR: hsync width");  end
                    if (m_vslow  != 1600)   begin errors = errors + 1; $display("ERROR: vsync width");  end
                end

                clkc = 0; linesc = 0; pixc = 0; alinesc = 0; hslow = 0; vslow = 0;
                frame = frame + 1;
            end
        end
    end

    // ------------------------------------------- RGB reconstruction (CSC inv)
    function [7:0] clamp8;
        input integer v;
        begin
            clamp8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
        end
    endfunction

    integer yy, cbv, crv;
    reg [7:0] rimg, gimg, bimg;

    always @* begin
        yy  = py  - 16;
        cbv = pcb - 128;
        crv = pcr - 128;
        rimg = clamp8((1164*yy + 1596*crv) / 1000);
        gimg = clamp8((1164*yy -  391*cbv - 813*crv) / 1000);
        bimg = clamp8((1164*yy + 2018*cbv) / 1000);
    end

    // ------------------------------------------------- patch & file plumbing
    reg     dumping = 1'b0;
    integer fh;
    integer frames_dumped = 0;
    integer over_count    = 0;
    reg     last_over     = 1'b0;
    integer over_after_force = 0;
    integer score_at_170  = -1;
    reg     collision_test_done = 1'b0;

    task open_dump;
        input [8*32-1:0] name;
        begin
            fh = $fopen(name, "wb");
            $fwrite(fh, "P6\n640 480\n255\n");
            dumping = 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst) begin
            // ------------------------------------------------ IMAGE DUMPS
            if (tick && frame == 2)   open_dump("frame_title.ppm");
            if (tick && frame == 34)  open_dump("frame_over.ppm");
            if (tick && frame == 155) open_dump("frame_play.ppm");

            if (dumping && de)
                $fwrite(fh, "%c%c%c", rimg, gimg, bimg);

            // de is high while hcnt is 1..640, so the last active pixel of the
            // last line is written when the counter reads 640
            if (dumping && de && hcnt == 10'd640 && vcnt == 10'd479) begin
                $fclose(fh);
                dumping = 1'b0;
                frames_dumped = frames_dumped + 1;
                $display(">> dumped image %0d at game frame %0d (state=%0s score=%0d%0d%0d)",
                         frames_dumped, frame, sname, score_h, score_t, score_o);
            end

            // ------------------------------------------------ STIMULUS
            if (tick) begin
                if (frame == 3)
                    flap = 1'b1;                       // start the game
                else if (frame == 40)
                    flap = 1'b1;                       // restart from OVER
                else if (frame >= 41 && frame <= 174)
                    flap = (bird_y > 10'd200);         // autopilot
                else
                    flap = 1'b0;
            end else begin
                flap = 1'b0;
            end

            // -------------------------- white-box pipe collision test
            if (tick && frame == 175 && !collision_test_done) begin
                collision_test_done = 1'b1;
                $display(">> forcing pipe 0 onto the bird with the gap out of reach");
                force u_game.pipe_x0 = 10'd98;         // overlaps the bird's box
                force u_game.gap0    = 10'd0;          // gap at the top, bird is below
            end

            // ------------------------------------------------ OBSERVATION
            if (tick && frame == 170)
                score_at_170 = {score_h, score_t, score_o};

            if (state == 2'd3 && !last_over) begin
                over_count = over_count + 1;
                $display(">> game over #%0d at frame %0d (score %0d%0d%0d)",
                         over_count, frame, score_h, score_t, score_o);
                if (collision_test_done && over_after_force == 0)
                    over_after_force = 1;
            end
            last_over = (state == 2'd3);

            // ------------------------------------------------ FINISH
            if (frame >= 210) begin
                $display("=== simulation finished (frame %0d) ===", frame);

                if (frames_dumped != 3) begin
                    $display("ERROR: expected 3 images, got %0d", frames_dumped);
                    errors = errors + 1;
                end
                if (over_count < 2) begin
                    $display("ERROR: expected two game overs (ground and pipe), got %0d", over_count);
                    errors = errors + 1;
                end
                if (score_at_170 != 1) begin
                    $display("ERROR: expected score 001 after passing one pipe, got %0d", score_at_170);
                    errors = errors + 1;
                end
                if (over_after_force != 1) begin
                    $display("ERROR: the forced pipe collision did not end the game");
                    errors = errors + 1;
                end

                if (errors == 0) $display("TEST PASSED");
                else             $display("TEST FAILED: %0d errors", errors);
                $finish;
            end
        end
    end

    // ------------------------------------------------------- game state trace
    always @(posedge clk) begin
        if (!rst && tick &&
            (frame < 8 || (frame > 148 && frame < 162) || (frame > 173 && frame < 184)))
            $display("frame=%0d state=%0s bird_y=%0d pipes=%0d/%0d/%0d gaps=%0d/%0d/%0d score=%0d%0d%0d",
                     frame, sname, bird_y, px0, px1, px2, gap0, gap1, gap2,
                     score_h, score_t, score_o);
    end

    // ------------------------------------------ 16-bit YCbCr 4:2:2 bus check
    // The packing register adds one pixel-clock of delay, so the word on the bus
    // while hcnt == n carries the data of pixel n-1.  Capture the palette output
    // for pixels 4 and 5, then compare with the bus words one clock later.
    reg [7:0]  py4, pcb4, pcr4, py5;
    reg [15:0] w4, w5;
    reg        bus_checked = 1'b0;

    always @(posedge clk) begin
        if (!rst && de && vcnt == 10'd100) begin
            if (hcnt == 10'd4) begin py4 <= py; pcb4 <= pcb; pcr4 <= pcr; end
            if (hcnt == 10'd5) begin py5 <= py; w4  <= vid_d; end
            if (hcnt == 10'd6) w5 <= vid_d;
        end
    end

    always @(posedge clk) begin
        if (!rst && !bus_checked && vid_de && vcnt == 10'd101 && hcnt == 10'd3) begin
            bus_checked = 1'b1;
            $display("--- 16-bit YCbCr 4:2:2 bus check (line 100) ---");
            $display("palette pixel 4 : Y=%0d Cb=%0d Cr=%0d", py4, pcb4, pcr4);
            $display("palette pixel 5 : Y=%0d", py5);
            $display("bus word pixel 4 = %h -> C=%0d Y=%0d", w4, w4[15:8], w4[7:0]);
            $display("bus word pixel 5 = %h -> C=%0d Y=%0d", w5, w5[15:8], w5[7:0]);

            if (w4[15:8] !== pcb4) begin
                $display("ERROR: the even pixel must carry Cb in the high byte");
                errors = errors + 1;
            end else $display("   ok: even pixel carries Cb (%0d) in the high byte", pcb4);

            if (w4[7:0] !== py4) begin
                $display("ERROR: even pixel luma byte wrong");
                errors = errors + 1;
            end else $display("   ok: even pixel luma byte = %0d", py4);

            if (w5[15:8] !== pcr4) begin
                $display("ERROR: the odd pixel must carry the pair's Cr (%0d), got %0d",
                         pcr4, w5[15:8]);
                errors = errors + 1;
            end else $display("   ok: odd pixel carries the pair's Cr (%0d) -- chroma shared by the pair", pcr4);

            if (w5[7:0] !== py5) begin
                $display("ERROR: odd pixel luma byte wrong");
                errors = errors + 1;
            end else $display("   ok: odd pixel luma byte = %0d", py5);
        end
    end

    // ------------------------------------------------------------ bootstrap
    initial begin
        $display("=== tb_flappy_system ===");
        repeat (10) @(posedge clk);
        rst = 1'b0;
    end

endmodule
