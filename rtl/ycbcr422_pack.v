// ============================================================================
//  ycbcr422_pack.v -- pack 4:4:4 pixel data into the ADV7511's 16-bit
//  YCbCr 4:2:2 bus format.
//
//  Board wiring (KC705 schematic): the FPGA's HDMI_D[15:0] lands on the
//  transmitter's D[23:8], and within that the UPPER byte of the FPGA bus is
//  the transmitter's luma field and the LOWER byte is its chroma field:
//      D[23:16] = Y[7:0]     <-- HDMI_D[15:8]
//      D[15:8]  = CbCr[7:0]  <-- HDMI_D[7:0]
//  So on each pixel clock the packed word is {luma, chroma}: luma every pixel,
//  chroma (Cb on the even pixel of the pair, Cr on the odd pixel) shared by
//  the pixel pair.  Getting this backwards feeds the transmitter's luma input
//  with chroma and vice versa.
//
//  DE is delayed in step with the data so the first pair starts exactly at the
//  first active pixel (pixel pairs are aligned to DE).
// ============================================================================
`timescale 1ns / 1ps

module ycbcr422_pack (
    input  wire        clk,
    input  wire        rst,
    input  wire        de,
    input  wire        hsync,
    input  wire        vsync,
    input  wire [9:0]  hcnt,        // pixel counter (hcnt[0] = 0 on the first active pixel)
    input  wire [7:0]  pix_y,
    input  wire [7:0]  pix_cb,
    input  wire [7:0]  pix_cr,
    output reg  [15:0] vid_d,
    output reg         vid_de,
    output reg         vid_hs,
    output reg         vid_vs
);

    reg [7:0] cb_hold, cr_hold;

    always @(posedge clk) begin
        if (rst) begin
            cb_hold <= 8'd128;
            cr_hold <= 8'd128;
            vid_d   <= 16'h1080;      // Y = 16, C = 128 (blanking)
            vid_de  <= 1'b0;
            vid_hs <= 1'b0;
            vid_vs <= 1'b0;
        end else begin
            // latch the chroma of the even pixel so the odd pixel can reuse it
            if (de && !hcnt[0]) begin
                cb_hold <= pix_cb;
                cr_hold <= pix_cr;
            end

            vid_de <= de;
            vid_hs <= hsync;
            vid_vs <= vsync;

            // Byte order: {luma, chroma} -- see the header note.  The upper
            // byte of HDMI_D is the transmitter's luma input.
            if (de)
                vid_d <= hcnt[0] ? {pix_y, cr_hold}     // odd pixel: Cr from the even one
                                 : {pix_y, pix_cb};    // even pixel: Cb
            else
                vid_d <= 16'h1080;
        end
    end

endmodule
