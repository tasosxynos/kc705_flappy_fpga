// ============================================================================
//  adv7511_status.v -- poll the ADV7511's registers over I2C.
//
//  Once the configuration sequence has run (init_done), this cycles through
//  three registers and latches what they say:
//
//      0x42 : [6] = HPD pin state      [5] = monitor sense (TMDS clock
//                                          termination detected in the sink)
//      0x9E : [4] = input PLL lock     (0 = the chip is not locking to our
//                                          pixel clock, 1 = locked.  In main
//                                          power down this stays 0.)
//      0xD6 : [7:6] = HPD control read back.  The init sequence writes 0xC0
//                                          (HPD forced high).  0xD6 is in the
//                                          0xCD-0xFF range, which the chip does
//                                          NOT reset while the HPD pin is low,
//                                          so reading 0xC0 back proves both
//                                          that the write stuck and that the
//                                          read path really works.
//
//  Reading 0x42 alone cannot tell "HPD really is low" apart from "the read
//  silently returns 0x00" - both look identical on an LED.  The 0xD6 read-back
//  is what validates everything else the panel shows.
//
//  hpd_rise pulses for one cycle when HPD goes from low to high; the top level
//  uses it to re-run the configuration, because the transmitter only powers up
//  while the HPD pin is high (programming guide Table 73).
// ============================================================================
`timescale 1ns / 1ps

module adv7511_status #(
    parameter [23:0] POLL_CNT = 24'd12_500_000,   // ~0.5 s per register
    parameter [6:0]  DEV      = 7'h39
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,       // poll only after the init sequence ran
    // command side of the I2C master
    output reg        i2c_start,
    output reg        i2c_rd,
    output reg  [6:0] i2c_dev,
    output reg  [15:0] i2c_wdata,
    input  wire       i2c_busy,
    input  wire       i2c_done,
    input  wire       i2c_err,
    input  wire [7:0] i2c_rdata,
    // decoded results
    output reg        hpd,
    output reg        sense,
    output reg        pll_lock,
    output reg  [7:0] d6_rb,        // read-back of register 0xD6 (expect 0xC0)
    output reg        rd_err,
    output reg        hpd_rise
);
    localparam [7:0] REG_42 = 8'h42,
                     REG_9E = 8'h9E,
                     REG_D6 = 8'hD6;

    localparam S_WAIT  = 2'd0,
               S_ASK   = 2'd1,
               S_POLL  = 2'd2,
               S_LATCH = 2'd3;

    reg [1:0]  state;
    reg [23:0] dcnt;
    reg        hpd_d;
    reg        asked;
    reg [1:0]  ridx;        // 0 = 0x42, 1 = 0x9E, 2 = 0xD6
    reg [7:0]  reqreg;      // register address of the read currently in flight

    function [7:0] regaddr;
        input [1:0] i;
        begin
            case (i)
            2'd0:    regaddr = REG_42;
            2'd1:    regaddr = REG_9E;
            default: regaddr = REG_D6;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_WAIT;
            dcnt      <= 24'd0;
            hpd_d     <= 1'b0;
            hpd       <= 1'b0;
            sense     <= 1'b0;
            pll_lock  <= 1'b0;
            d6_rb     <= 8'h00;
            rd_err    <= 1'b0;
            hpd_rise  <= 1'b0;
            i2c_start <= 1'b0;
            i2c_rd    <= 1'b0;
            i2c_dev   <= DEV;
            i2c_wdata <= {REG_42, 8'h00};
            asked     <= 1'b0;
            ridx      <= 2'd0;
            reqreg    <= REG_42;
        end else begin
            i2c_start <= 1'b0;
            hpd_rise  <= 1'b0;

            case (state)
            // --------------------------------------------------------------
            S_WAIT: begin
                i2c_rd <= 1'b0;
                if (enable) begin
                    dcnt  <= 24'd0;
                    ridx  <= 2'd0;
                    state <= S_ASK;
                end
            end
            // --------------------------------------------------------------
            // issue one single-byte read of regaddr(ridx)
            S_ASK: begin
                i2c_rd    <= 1'b1;
                i2c_dev   <= DEV;
                reqreg    <= regaddr(ridx);
                i2c_wdata <= {regaddr(ridx), 8'h00};
                if (!enable) begin
                    asked <= 1'b0;
                    state <= S_WAIT;
                end else if (!asked) begin
                    if (!i2c_busy) begin
                        i2c_start <= 1'b1;
                        asked     <= 1'b1;
                    end
                end else begin
                    asked <= 1'b0;
                    state <= S_POLL;
                end
            end
            // --------------------------------------------------------------
            S_POLL: begin
                if (i2c_done) begin
                    i2c_rd <= 1'b0;
                    if (i2c_err) begin
                        rd_err <= 1'b1;
                    end else begin
                        rd_err <= 1'b0;
                        case (reqreg)
                        REG_42: begin
                            hpd   <= i2c_rdata[6];
                            sense <= i2c_rdata[5];
                            if (i2c_rdata[6] && !hpd_d)
                                hpd_rise <= 1'b1;
                            hpd_d <= i2c_rdata[6];
                        end
                        REG_9E: pll_lock <= i2c_rdata[4];
                        default: d6_rb   <= i2c_rdata;
                        endcase
                    end
                    // rotate 0x42 -> 0x9E -> 0xD6 -> 0x42
                    ridx  <= (ridx == 2'd2) ? 2'd0 : ridx + 2'd1;
                    state <= S_LATCH;
                end
            end
            // --------------------------------------------------------------
            S_LATCH: begin
                if (dcnt == POLL_CNT) begin
                    dcnt  <= 24'd0;
                    state <= S_ASK;
                end else begin
                    dcnt <= dcnt + 24'd1;
                end
            end
            default: state <= S_WAIT;
            endcase
        end
    end

endmodule
