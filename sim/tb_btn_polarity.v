// ============================================================================
//  tb_btn_polarity.v -- checks the pushbutton conditioning logic.
//
//  The KC705 documentation does not state clearly whether SW5 idles high
//  (switch to ground) or idles low (switch to supply), so btn_input detects it
//  at power-up.  Both wirings are simulated here:
//
//    device A: pin idles HIGH  -> must detect active-low, press on the low pulse
//    device B: pin idles LOW   -> must detect active-high, press on the high pulse
//
//  Also checks that contact bounce does not generate extra presses.
//
//  Run with:   xsim tb_btn_polarity -R
// ============================================================================
`timescale 1ns / 1ps

module tb_btn_polarity;

    reg clk = 1'b0;
    always #20 clk = ~clk;                 // 25 MHz

    // ------------------------------------------------------- device A (idle 1)
    reg  rst_a = 1'b1;
    reg  pin_a = 1'b1;                     // idles HIGH -> active low
    wire press_a, level_a, alow_a, det_a;

    btn_input #(.CLK_HZ(25_000_000), .DETECT_MS(1), .DEBOUNCE_MS(1)) dut_a (
        .clk(clk), .rst(rst_a), .pin(pin_a),
        .press(press_a), .level(level_a),
        .active_low(alow_a), .detect_done(det_a)
    );

    // ------------------------------------------------------- device B (idle 0)
    reg  rst_b = 1'b1;
    reg  pin_b = 1'b0;                     // idles LOW -> active high
    wire press_b, level_b, alow_b, det_b;

    btn_input #(.CLK_HZ(25_000_000), .DETECT_MS(1), .DEBOUNCE_MS(1)) dut_b (
        .clk(clk), .rst(rst_b), .pin(pin_b),
        .press(press_b), .level(level_b),
        .active_low(alow_b), .detect_done(det_b)
    );

    integer errors    = 0;
    integer presses_a = 0;
    integer presses_b = 0;

    always @(posedge clk) begin
        if (press_a) presses_a = presses_a + 1;
        if (press_b) presses_b = presses_b + 1;
    end

    initial begin
        $display("=== tb_btn_polarity ===");
        repeat (5) @(posedge clk);
        rst_a = 1'b0;
        rst_b = 1'b0;

        // let the polarity detection window (1 ms = 25000 clocks) pass
        repeat (40000) @(posedge clk);

        // ---- detection ----
        if (!det_a || !det_b) begin
            $display("ERROR: detection did not complete");
            errors = errors + 1;
        end
        if (alow_a !== 1'b1) begin
            $display("ERROR: device A (idles high) must detect active-low, got %b", alow_a);
            errors = errors + 1;
        end else $display("   ok: idle-high wiring detected as active-low");
        if (alow_b !== 1'b0) begin
            $display("ERROR: device B (idles low) must detect active-high, got %b", alow_b);
            errors = errors + 1;
        end else $display("   ok: idle-low wiring detected as active-high");

        // ---- a clean press, with bounce at both edges ----
        // device A: press = pull low, with contact bounce
        fork
            begin : bounce_a
                integer i;
                for (i = 0; i < 6; i = i + 1) begin
                    pin_a = 1'b0; #100000;
                    pin_a = 1'b1; #100000;
                end
                pin_a = 1'b0;          // settle pressed
                #4000000;
                for (i = 0; i < 6; i = i + 1) begin
                    pin_a = 1'b1; #100000;
                    pin_a = 1'b0; #100000;
                end
                pin_a = 1'b1;          // settle released
            end
            begin : bounce_b
                integer i;
                for (i = 0; i < 6; i = i + 1) begin
                    pin_b = 1'b1; #100000;
                    pin_b = 1'b0; #100000;
                end
                pin_b = 1'b1;          // settle pressed
                #4000000;
                for (i = 0; i < 6; i = i + 1) begin
                    pin_b = 1'b0; #100000;
                    pin_b = 1'b1; #100000;
                end
                pin_b = 1'b0;          // settle released
            end
        join

        // wait long enough for the release to debounce (1 ms debounce time)
        repeat (50000) @(posedge clk);

        $display("presses: device A = %0d, device B = %0d (expect 1 each)", presses_a, presses_b);
        if (presses_a != 1) begin
            $display("ERROR: device A generated %0d presses, expected 1", presses_a);
            errors = errors + 1;
        end
        if (presses_b != 1) begin
            $display("ERROR: device B generated %0d presses, expected 1", presses_b);
            errors = errors + 1;
        end
        if (level_a !== 1'b0) begin
            $display("ERROR: device A level stuck pressed");
            errors = errors + 1;
        end
        if (level_b !== 1'b0) begin
            $display("ERROR: device B level stuck pressed");
            errors = errors + 1;
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule
