// ============================================================================
//  tb_render_probe.v -- isolated sweep test for render_flappy.
//
//  Drives the renderer with a frozen, known game state (the one from the play
//  frame: bird_y=176, pipes 22/342/662, gaps 90/150/120, score 001) and sweeps
//  a whole frame, printing:
//    * the histogram of palette indices actually produced,
//    * internal signals at a few probe pixels (p0_on/p1_on/p2_on, the colour
//      functions, the text/score enables) so the priority chain can be traced.
//
//  Pure combinational logic, so no clock is needed -- a full frame takes a few
//  hundred microseconds of simulator time.
// ============================================================================
`timescale 1ns / 1ps

module tb_render_probe;

    reg  [9:0] x = 10'd0, y = 10'd0;
    reg  [1:0] state      = 2'd1;          // S_PLAY
    reg  [9:0] bird_y     = 10'd176;
    reg  [1:0] bird_frame = 2'd0;
    reg  [3:0] score_h = 4'd0, score_t = 4'd0, score_o = 4'd1;
    reg        show_score = 1'b1;
    reg  [9:0] pipe_x0 = 10'd22, pipe_x1 = 10'd342, pipe_x2 = 10'd662;
    reg  [9:0] gap0    = 10'd90, gap1    = 10'd150, gap2    = 10'd120;
    reg  [9:0] scroll  = 10'd0;
    wire [4:0] pidx;

    render_flappy u_rend (
        .x(x), .y(y),
        .state(state), .bird_y(bird_y), .bird_frame(bird_frame),
        .score_h(score_h), .score_t(score_t), .score_o(score_o),
        .show_score(show_score),
        .pipe_x0(pipe_x0), .pipe_x1(pipe_x1), .pipe_x2(pipe_x2),
        .gap0(gap0), .gap1(gap1), .gap2(gap2),
        .scroll(scroll),
        .pidx(pidx)
    );

    integer counts [0:31];
    integer i, xx, yy;

    task probe;
        input [9:0] px;
        input [9:0] py;
        input [8*32-1:0] what;
        begin
            x = px; y = py; #1;
            $display("%0s (%0d,%0d): pidx=%0d p0_on=%b p0_c=%0d p1_on=%b p2_on=%b hill_on=%b sc_on=%b sc_pix=%b t_on=%b",
                     what, px, py, pidx,
                     u_rend.p0_on, u_rend.p0_c, u_rend.p1_on, u_rend.p2_on,
                     u_rend.hill_on, u_rend.sc_on, u_rend.sc_pix, u_rend.t_on);
        end
    endtask

    initial begin
        $display("=== tb_render_probe: sweeping one full frame ===");
        for (i = 0; i < 32; i = i + 1) counts[i] = 0;
        for (yy = 0; yy < 480; yy = yy + 1) begin
            for (xx = 0; xx < 640; xx = xx + 1) begin
                x = xx;
                y = yy;
                #1;
                counts[pidx] = counts[pidx] + 1;
            end
        end

        $display("--- palette index histogram over the whole frame ---");
        for (i = 0; i < 32; i = i + 1)
            if (counts[i] != 0) $display("  idx %0d : %0d px", i, counts[i]);
        $display("  (expect pipe indices 12/13/14 to be non-zero)");

        $display("--- probe pixels ---");
        probe(10'd50,  10'd50,  "pipe 0 column, above gap ");
        probe(10'd50,  10'd150, "pipe 0 column, in gap   ");
        probe(10'd350, 10'd50,  "pipe 1 column, above gap");
        probe(10'd350, 10'd200, "pipe 1 column, in gap   ");
        probe(10'd100, 10'd176, "bird                   ");
        probe(10'd320, 10'd16,  "score digits           ");
        probe(10'd320, 10'd300, "plain sky              ");
        $display("=== done ===");
        $finish;
    end

endmodule
