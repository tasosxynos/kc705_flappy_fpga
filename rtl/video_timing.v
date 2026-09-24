// ============================================================================
//  video_timing.v -- 1920x1080 @ 60 Hz (1080p60, CEA-861 format 16) generator
//
//  This is the mode the KC705's HDMI path is specified for; UG810 says of the
//  ADV7511 circuit: "wired to support 1080P 60Hz, YCbCr 4:2:2 encoding via
//  16-bit input data mapping".
//
//  CEA-861 1080p60 timings, pixel clock 148.5 MHz:
//      horizontal: 1920 active + 88 front porch + 44 sync + 148 back porch = 2200
//      vertical:   1080 active +  4 front porch +  5 sync +  36 back porch = 1125
//      148.5e6 / (2200 * 1125) = 60.00 Hz exactly
//
//  Sync polarity for 1080p60 is POSITIVE (active high), unlike 640x480.  This
//  matters in DVI mode, where the sink reconstructs the timing from the syncs
//  alone: the ADV7511 passes the input sync polarity straight through when the
//  sync adjustment bit 0x41[1] = 0 (register 0x17[6:5] = 0 keeps it at pass
//  through), so what this module drives is what the TMDS stream carries.
//
//  Outputs hcnt/vcnt which ARE the pixel coordinates while de is high, so
//  downstream logic can use them directly as (x, y).
// ============================================================================
`timescale 1ns / 1ps

module video_timing (
    input  wire        clk,
    input  wire        rst,
    output reg  [11:0] hcnt,        // 0..2199
    output reg  [10:0] vcnt,        // 0..1124
    output reg         hsync,       // positive polarity (active high)
    output reg         vsync,       // positive polarity (active high)
    output reg         de,          // data enable (active pixel)
    output reg         frame_tick   // 1-cycle pulse at the start of each frame
);

    localparam H_ACT   = 1920;
    localparam H_FP    = 88;
    localparam H_SYNC  = 44;
    localparam H_BP    = 148;
    localparam H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;      // 2200

    localparam V_ACT   = 1080;
    localparam V_FP    = 4;
    localparam V_SYNC  = 5;
    localparam V_BP    = 36;
    localparam V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;      // 1125

    localparam H_SYNC_START = H_ACT + H_FP;                 // 2008
    localparam H_SYNC_END   = H_ACT + H_FP + H_SYNC - 1;    // 2051
    localparam V_SYNC_START = V_ACT + V_FP;                 // 1084
    localparam V_SYNC_END   = V_ACT + V_FP + V_SYNC - 1;    // 1088

    wire h_last = (hcnt == H_TOTAL - 1);
    wire v_last = (vcnt == V_TOTAL - 1);

    always @(posedge clk) begin
        if (rst) begin
            hcnt  <= 12'd0;
            vcnt  <= 11'd0;
            de       <= 1'b0;
            hsync    <= 1'b0;
            vsync    <= 1'b0;
            frame_tick <= 1'b0;
        end else begin
            // ---- counters ----
            if (h_last) begin
                hcnt <= 12'd0;
                vcnt <= v_last ? 11'd0 : vcnt + 11'd1;
            end else begin
                hcnt <= hcnt + 12'd1;
            end

            // ---- data enable ----
            de <= (hcnt < H_ACT) && (vcnt < V_ACT);

            // ---- syncs (active high) ----
            hsync <= (hcnt >= H_SYNC_START) && (hcnt <= H_SYNC_END);
            vsync <= (vcnt >= V_SYNC_START) && (vcnt <= V_SYNC_END);

            // ---- frame tick: one clock at the top-left of each frame ----
            frame_tick <= h_last && v_last;
        end
    end

endmodule
