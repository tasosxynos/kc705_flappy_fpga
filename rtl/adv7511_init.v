// ============================================================================
//  adv7511_init.v -- power-on configuration of the KC705 HDMI transmitter.
//
//  The KC705's HDMI output is an Analog Devices ADV7511 (U65) driven with
//  *parallel* LVCMOS25 video (there is no TMDS encoder in the FPGA).  The chip
//  is NOT a passive PHY: it must be programmed over I2C before it will output
//  anything.  It sits behind a PCA9548 I2C switch at address 0x74, on channel 5.
//
//  Target configuration:
//      640x480 @ 60 Hz, 16-bit YCbCr 4:2:2 input with separate syncs (Input
//      ID 1, input style 1), internal colour-space converter turned back into
//      RGB, DVI output mode (no audio, no HDCP).
//
//  Register values are taken from the ADV7511W Programming Guide, rev. B:
//    * 4.3.3 Input ID / 4.3.4 Input Style          -> 0x15, 0x16, 0x48
//    * "Fixed Registers That Must Be Set"          -> 0x98, 0x9A, 0x9C, 0x9D,
//                                                     0xA2, 0xA3, 0xE0, 0xF9, 0x55
//    * Table 32 "HDTV YCbCr (limited range) to RGB (limited range)"
//                                                  -> 0x18 .. 0x2F (the CSC)
//    * 4.3.4 / 4.2.3                               -> 0xAF (DVI mode), 0xD6 (HPD)
//
//  A NACK from any device restarts the whole sequence after ~21 ms, so the
//  design is robust against the chip being slower to power up than the FPGA.
// ============================================================================
`timescale 1ns / 1ps

module adv7511_init #(
    // Delay counts, overridable so the whole sequence can be simulated quickly.
    parameter [20:0] POR_CNT   = 21'h1FFFFF,  // ~84 ms @ 25 MHz
    parameter [11:0] GAP_CNT   = 12'd2499,    // ~100 us between transfers
    parameter [19:0] RETRY_CNT = 20'h7FFFF    // ~21 ms before a retry
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        restart,      // pulse: run the whole sequence again
    // command interface to i2c_master
    output reg         i2c_start,
    output reg  [6:0]  i2c_dev,
    output reg  [15:0] i2c_wdata,     // {byte1, byte2}
    output reg         i2c_nbytes,    // 1 = one byte, 0 = two bytes
    input  wire        i2c_busy,
    input  wire        i2c_done,
    input  wire        i2c_err,
    // status
    output reg         init_done,     // config sequence finished cleanly
    output reg         err_latch      // sticky "a NACK was seen" flag
);

    localparam [6:0] MUX_ADDR = 7'h74;        // PCA9548 I2C switch
    localparam [6:0] ADV_ADDR = 7'h39;        // ADV7511 (0x72 >> 1)
    localparam [5:0] LAST_STEP = 6'd48;       // 1 mux write + 48 register writes

    // ---- delays (counts come from the module parameters above) --------------

    localparam S_POR = 3'd0, S_SEND = 3'd1, S_WAIT = 3'd2,
               S_GAP = 3'd3, S_DONE = 3'd4, S_RETRY = 3'd5;

    reg [2:0]  state;
    reg [5:0]  step;
    reg [20:0] dcnt;
    reg        started;       // start pulse already issued for this step

    // ---- register table ----------------------------------------------------
    // step 0 is the I2C mux; every other step is an ADV7511 register write.
    function [15:0] tbl;
        input [5:0] s;
        begin
            case (s)
            6'd0 : tbl = {8'h20, 8'h00};   // PCA9548: enable channel 5
            // --- power and the mandatory "fixed" registers ------------------
            // 0xD6[7:6] = 11 forces the transmitter's internal HPD high, and it
            // has to happen BEFORE the power-up write: per the programming guide
            // (4.2.1) the power-down bit 0x41[6] "must be written to 0 when the
            // HPD pin is high", and while HPD is low "some registers cannot be
            // written to".  On this board both HPD and monitor sense read 0, so
            // taking HPD from the pin (0x00) would leave every following write,
            // including 0x15/0x16/0x48/0xAF, at the mercy of that rule.
            6'd1 : tbl = {8'hD6, 8'hC0};   // HPD forced high (bring-up override)
            // --- power and the mandatory "fixed" registers ------------------
            6'd2 : tbl = {8'h41, 8'h10};   // power up (HPD already forced high)
            6'd3 : tbl = {8'h9A, 8'hE0};   // fixed register (ADI)
            6'd4 : tbl = {8'h9C, 8'h30};   // fixed register (ADI)
            6'd5 : tbl = {8'h9D, 8'h61};   // fixed register (ADI)
            6'd6 : tbl = {8'hA2, 8'hA4};   // fixed register (ADI)
            6'd7 : tbl = {8'hA3, 8'hA4};   // fixed register (ADI)
            6'd8 : tbl = {8'hE0, 8'hD0};   // fixed register (ADI)
            6'd9 : tbl = {8'hF9, 8'h00};   // fixed register (ADI)
            6'd10: tbl = {8'h55, 8'h02};   // fixed register (ADI)
            // --- input format ----------------------------------------------
            6'd11: tbl = {8'h15, 8'h01};   // Input ID 1: 16-bit YCbCr 4:2:2, sep. syncs
            6'd12: tbl = {8'h16, 8'h3C};   // style 3 -- locked in from the sweeper
            6'd13: tbl = {8'h48, 8'h08};   // 4:2:2 -> 4:4:4, RIGHT justified (sweep winner)
            // --- output / misc ---------------------------------------------
            6'd14: tbl = {8'hAF, 8'h04};   // DVI mode (bit 1 = 0), HDCP disabled
            // 0x98 is one of the fixed registers that normally follows the power
            // up write immediately; it sits here so that hoisting the HPD
            // override to step 1 keeps the byte count, the pairing and every
            // downstream index unchanged.  It is a static setting, so its exact
            // position in the sequence does not matter.
            6'd15: tbl = {8'h98, 8'h03};   // fixed register (ADI)
            // --- colour space converter: YCbCr -> RGB (PG Table 32) --------
            // Production matrix.  The register values are the guide's verbatim
            // values for "HDTV YCbCr (Limited Range) to RGB (Limited Range)".
            6'd16: tbl = {8'h18, 8'hAC};   // CSC enable + A1
            6'd17: tbl = {8'h19, 8'h53};
            6'd18: tbl = {8'h1A, 8'h08};   // A2
            6'd19: tbl = {8'h1B, 8'h00};
            6'd20: tbl = {8'h1C, 8'h00};   // A3
            6'd21: tbl = {8'h1D, 8'h00};
            6'd22: tbl = {8'h1E, 8'h19};   // A4 (offset)
            6'd23: tbl = {8'h1F, 8'hD6};
            6'd24: tbl = {8'h20, 8'h1C};   // B1
            6'd25: tbl = {8'h21, 8'h56};
            6'd26: tbl = {8'h22, 8'h08};   // B2
            6'd27: tbl = {8'h23, 8'h00};
            6'd28: tbl = {8'h24, 8'h1E};   // B3
            6'd29: tbl = {8'h25, 8'h88};
            6'd30: tbl = {8'h26, 8'h02};   // B4 (offset)
            6'd31: tbl = {8'h27, 8'h91};
            6'd32: tbl = {8'h28, 8'h1F};   // C1
            6'd33: tbl = {8'h29, 8'hFF};
            6'd34: tbl = {8'h2A, 8'h08};   // C2
            6'd35: tbl = {8'h2B, 8'h00};
            6'd36: tbl = {8'h2C, 8'h0E};   // C3
            6'd37: tbl = {8'h2D, 8'h85};
            6'd38: tbl = {8'h2E, 8'h18};   // C4 (offset)
            6'd39: tbl = {8'h2F, 8'hBE};
            6'd40: tbl = {8'h41, 8'h10};   // re-assert power up after the CSC write
            // --- input capture trim + remaining ADI recommended writes -------
            // 0xBA is the *input video clock* sampling delay: the ADV7511
            // latches the parallel bus on an internally delayed clock and,
            // without it, the capture sits too close to the data transitions.
            // A marginal capture shows up as pixel noise that is worst where
            // the bus toggles hardest (big chroma swings), which is exactly
            // the signature the colour-bar test image produced.
            6'd41: tbl = {8'hBA, 8'hA0};   // input clock delay = 101 = +0.8 ns
            6'd42: tbl = {8'hD0, 8'h00};   // neg. edge DDR delay adjust = off
            6'd43: tbl = {8'h99, 8'h02};   // fixed register (ADI)
            6'd44: tbl = {8'hA5, 8'h44};   // fixed register (ADI)
            6'd45: tbl = {8'hAB, 8'h40};   // fixed register (ADI)
            6'd46: tbl = {8'hD1, 8'hFF};   // fixed register (ADI)
            6'd47: tbl = {8'hDE, 8'h9C};   // fixed register (ADI)
            6'd48: tbl = {8'hE4, 8'h60};   // VCO swing reference voltage (ADI)
            default: tbl = {8'h00, 8'h00};
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_POR;
            step       <= 6'd0;
            dcnt       <= 21'd0;
            started    <= 1'b0;
            i2c_start  <= 1'b0;
            i2c_dev    <= ADV_ADDR;
            i2c_wdata  <= 16'h0;
            i2c_nbytes <= 1'b0;
            init_done  <= 1'b0;
            err_latch  <= 1'b0;
        end else begin
            i2c_start <= 1'b0;

            if (restart) begin
                // Re-run the configuration from the top.  The ADV7511 powers up
                // its transmitter only once HPD is high, so whenever the sink is
                // plugged in (or wakes up) after power-on, the sequence has to
                // run again.
                state     <= S_POR;
                step      <= 6'd0;
                dcnt      <= 21'd0;
                started   <= 1'b0;
                init_done <= 1'b0;
            end else
            case (state)
            // ---------------------------------------------------------------
            S_POR: begin
                if (dcnt == POR_CNT) begin
                    dcnt  <= 21'd0;
                    step  <= 6'd0;
                    state <= S_SEND;
                end else begin
                    dcnt <= dcnt + 21'd1;
                end
            end
            // ---------------------------------------------------------------
            S_SEND: begin
                // load the current step into the I2C master
                i2c_dev    <= (step == 6'd0) ? MUX_ADDR : ADV_ADDR;
                i2c_nbytes <= (step == 6'd0) ? 1'b1     : 1'b0;
                i2c_wdata  <= tbl(step);
                if (!started) begin
                    if (!i2c_busy) begin
                        i2c_start <= 1'b1;
                        started   <= 1'b1;
                    end
                end else begin
                    state  <= S_WAIT;
                    started <= 1'b0;
                end
            end
            // ---------------------------------------------------------------
            S_WAIT: begin
                if (i2c_done) begin
                    if (i2c_err) begin
                        err_latch <= 1'b1;
                        dcnt      <= 20'd0;
                        state     <= S_RETRY;      // something NACKed -> start over
                    end else begin
                        dcnt  <= 12'd0;
                        state <= S_GAP;
                    end
                end
            end
            // ---------------------------------------------------------------
            S_GAP: begin
                if (dcnt == {8'd0, GAP_CNT}) begin
                    dcnt <= 21'd0;
                    if (step == LAST_STEP) begin
                        state <= S_DONE;
                    end else begin
                        step  <= step + 6'd1;
                        state <= S_SEND;
                    end
                end else begin
                    dcnt <= dcnt + 21'd1;
                end
            end
            // ---------------------------------------------------------------
            S_DONE: begin
                init_done <= 1'b1;
            end
            // ---------------------------------------------------------------
            S_RETRY: begin
                if (dcnt == {1'b0, RETRY_CNT}) begin
                    dcnt  <= 21'd0;
                    step  <= 6'd0;
                    state <= S_SEND;
                end else begin
                    dcnt <= dcnt + 21'd1;
                end
            end
            // ---------------------------------------------------------------
            default: state <= S_POR;
            endcase
        end
    end

endmodule
