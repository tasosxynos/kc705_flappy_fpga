// ============================================================================
//  btn_input.v -- pushbutton conditioning.
//
//  1. Two-flop synchroniser for the asynchronous pin.
//  2. Polarity auto-detection: for the first DETECT_MS after reset the pin is
//     sampled and majority-voted.  A pushbutton that idles HIGH is wired
//     switch-to-ground (active low); one that idles LOW is wired
//     switch-to-supply (active high).  This makes the design work on boards
//     where the documentation is ambiguous, without a rebuild.
//     (Do not hold the button down while the FPGA is configuring.)
//  3. Debounce: the level must be stable for DEBOUNCE_MS before it is accepted.
//  4. One-cycle "press" pulse on the accepted falling/rising edge.
// ============================================================================
`timescale 1ns / 1ps

module btn_input #(
    parameter CLK_HZ      = 25_000_000,
    parameter DETECT_MS   = 32,
    parameter DEBOUNCE_MS = 10
) (
    input  wire clk,
    input  wire rst,
    input  wire pin,
    output reg  press,        // one-cycle pulse per press
    output reg  level,        // debounced pressed level
    output reg  active_low,   // detected wiring polarity
    output reg  detect_done
);
    localparam integer DET_CYCLES = (CLK_HZ / 1000) * DETECT_MS;
    localparam integer DEB_CYCLES = (CLK_HZ / 1000) * DEBOUNCE_MS;

    reg [1:0]  sync;
    reg [31:0] det_cnt;
    reg [31:0] hi_cnt;
    reg [31:0] db_cnt;
    reg        detecting;

    wire       pin_s = sync[1];
    wire       raw   = active_low ? ~pin_s : pin_s;

    always @(posedge clk) begin
        if (rst) begin
            sync        <= 2'b00;
            det_cnt     <= 32'd0;
            hi_cnt      <= 32'd0;
            db_cnt      <= 32'd0;
            detecting   <= 1'b1;
            detect_done <= 1'b0;
            active_low  <= 1'b0;
            level       <= 1'b0;
            press       <= 1'b0;
        end else begin
            sync  <= {sync[0], pin};
            press <= 1'b0;

            if (detecting) begin
                if (pin_s) hi_cnt <= hi_cnt + 32'd1;
                if (det_cnt == (DET_CYCLES - 1)) begin
                    detecting   <= 1'b0;
                    detect_done <= 1'b1;
                    // idles high  -> active low;  idles low -> active high
                    active_low  <= (hi_cnt > (DET_CYCLES / 2));
                end else begin
                    det_cnt <= det_cnt + 32'd1;
                end
            end else begin
                if (raw == level) begin
                    db_cnt <= 32'd0;
                end else if (db_cnt == (DEB_CYCLES - 1)) begin
                    db_cnt <= 32'd0;
                    level  <= raw;
                    if (raw) press <= 1'b1;
                end else begin
                    db_cnt <= db_cnt + 32'd1;
                end
            end
        end
    end

endmodule
