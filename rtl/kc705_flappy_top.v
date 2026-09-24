// ============================================================================
//  kc705_flappy_top.v -- Flappy Bird on the Xilinx Kintex-7 KC705.
//
//  Pure RTL, no processor, no Xilinx video IP.
//
//      SYSCLK (200 MHz LVDS, AD12/AD11)
//        -> MMCME2 -> 148.5 MHz pixel clock
//        -> video_timing -> 1920x1080@60, hsync/vsync/de (positive syncs)
//        -> render_flappy (combinational pixel generator)
//        -> gfx_palette (5-bit index -> YCbCr) -> 16-bit YCbCr 4:2:2
//        -> 18 parallel LVCMOS25 data lines + pixel clock
//        -> ADV7511 (U65) -> TMDS -> HDMI connector
//
//  The ADV7511 is programmed over I2C at power-up (adv7511_init / i2c_master)
//  because it is a real transmitter chip, not a passive PHY.
//
//  Controls: SW5 (centre pushbutton, GPIO_SW_C) makes the bird flap.
//  LEDs are the bring-up diagnostic panel (see the LED block at the end):
//      LED0 DS4  = MMCM locked              LED4 DS3  = 0xD6 read-back bit 7
//      LED1 DS1  = ADV7511 configured       LED5 DS25 = 0xD6 read-back bit 6
//      LED2 DS10 = monitor sense 0x42[5]    LED6 DS26 = input PLL lock 0x9E[4]
//      LED3 DS2  = HPD pin state 0x42[6]    LED7 DS27 = I2C read error
// ============================================================================
`timescale 1ns / 1ps

module kc705_flappy_top (
    input  wire        SYSCLK_P,
    input  wire        SYSCLK_N,
    // HDMI: 18-bit parallel video to the ADV7511 (HDMI_D[15:8]=chroma,
    // HDMI_D[7:0]=luma; D17/D16 unused in 16-bit mode)
    output wire [17:0] HDMI_D,
    output wire        HDMI_CLK,
    output wire        HDMI_DE,
    output wire        HDMI_HSYNC,
    output wire        HDMI_VSYNC,
    // user I/O
    input  wire        GPIO_SW_C,        // SW5, centre pushbutton
    // user LEDs: the bring-up diagnostic channel (see the LED block at the end)
    output wire        GPIO_LED_0,       // DS4  : MMCM locked
    output wire        GPIO_LED_1,       // DS1  : ADV7511 configured over I2C
    output wire        GPIO_LED_2,       // DS10 : monitor sense  0x42[5]
    output wire        GPIO_LED_3,       // DS2  : HPD pin state  0x42[6]
    output wire        GPIO_LED_4,       // DS3  : 0xD6 read-back bit 7
    output wire        GPIO_LED_5,       // DS25 : 0xD6 read-back bit 6
    output wire        GPIO_LED_6,       // DS26 : input PLL lock 0x9E[4]
    output wire        GPIO_LED_7,       // DS27 : I2C read error
    // I2C to the ADV7511 (through the PCA9548 switch).  SCL is output-only --
    // the master never reads it back -- so it uses OBUFT and infers no input
    // buffer.  SDA is genuinely bidirectional (the ACK bit is read).
    output wire        IIC_SCL_MAIN,
    inout  wire        IIC_SDA_MAIN,
    output wire        IIC_MUX_RESET_B
);

    // Pixel clock is 148.5 MHz for 1080p60 (see the MMCM below).  This value
    // feeds the I2C quarter-tick divider and the pushbutton debounce windows,
    // both of which are expressed in clock cycles.
    localparam CLK_HZ = 148_500_000;

    // ----------------------------------------------------------- 200 MHz input
    wire clk200;
    IBUFDS #(.DIFF_TERM("FALSE"), .IOSTANDARD("LVDS"))
    u_sysclk (.I(SYSCLK_P), .IB(SYSCLK_N), .O(clk200));

    // ------------------------------------------ 148.5 MHz pixel clock (1080p60)
    // VCO = 200 MHz * 37.125 / 10 = 742.5 MHz, CLKOUT0 = 742.5 / 5 = 148.5 MHz.
    // The fractional multiplier is what makes exactly 148.5 MHz reachable from
    // the 200 MHz reference.  The net keeps its historical `clk25` name.
    wire clk25_raw, clkfb, locked;
    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (37.125),
        .CLKIN1_PERIOD      (5.0),
        .CLKOUT0_DIVIDE_F   (5.0),
        .CLKOUT0_DUTY_CYCLE (0.5),
        .DIVCLK_DIVIDE      (10),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        .CLKOUT0   (clk25_raw),
        .CLKFBOUT  (clkfb),
        .CLKIN1    (clk200),
        .CLKFBIN   (clkfb),
        .LOCKED    (locked),
        .PWRDWN    (1'b0),
        .RST       (1'b0),
        .CLKOUT0B  (), .CLKOUT1  (), .CLKOUT1B (), .CLKOUT2  (), .CLKOUT2B (),
        .CLKOUT3   (), .CLKOUT3B (), .CLKOUT4  (), .CLKOUT5  (), .CLKOUT6  (),
        .CLKFBOUTB ()
    );

    wire clk25;
    BUFG u_bufg_pix (.I(clk25_raw), .O(clk25));

    // ------------------------------------------------------------------- reset
    reg [15:0] por = 16'd0;
    wire rst = ~locked | ~por[15];
    always @(posedge clk25)
        if (!por[15]) por <= por + 16'd1;

    // ------------------------------------------------------------- video timing
    wire [11:0] hcnt;
    wire [10:0] vcnt;
    wire       de, hs, vs, frame_tick;
    video_timing u_timing (
        .clk(clk25), .rst(rst),
        .hcnt(hcnt), .vcnt(vcnt),
        .hsync(hs), .vsync(vs),
        .de(de), .frame_tick(frame_tick)
    );

    // --------------------------------------------------------------- pushbutton
    wire flap, btn_level;
    btn_input #(.CLK_HZ(CLK_HZ), .DETECT_MS(32), .DEBOUNCE_MS(10)) u_btn (
        .clk(clk25), .rst(rst), .pin(GPIO_SW_C),
        .press(flap), .level(btn_level),
        .active_low(), .detect_done()
    );

    // -------------------------------------------------------------------- game
    wire [1:0]  state, bird_frame;
    wire [9:0]  bird_y, pipe_x0, pipe_x1, pipe_x2, gap0, gap1, gap2, scroll;
    wire [3:0]  score_h, score_t, score_o;
    wire [3:0]  hi_h, hi_t, hi_o;      // high score digits (undeclared here = 1-bit implicit net -> only bit 0 reached the renderer)
    wire        show_score;

    game_flappy u_game (
        .clk(clk25), .rst(rst),
        .tick(frame_tick), .flap(flap),
        .state(state), .bird_y(bird_y), .bird_frame(bird_frame),
        .score_h(score_h), .score_t(score_t), .score_o(score_o),
        .hi_h(hi_h), .hi_t(hi_t), .hi_o(hi_o),
        .show_score(show_score),
        .pipe_x0(pipe_x0), .pipe_x1(pipe_x1), .pipe_x2(pipe_x2),
        .gap0(gap0), .gap1(gap1), .gap2(gap2),
        .scroll(scroll)
    );

    // ------------------------------------------------- 1080p fill (2.25x scale)
    // render_flappy draws in its native 640x480 space.  Scale that image 2.25x
    // uniformly so it fills the full height of the 1920x1080 raster: it covers
    // columns 240..1679 (240 px black bars left and right) and all 1080 lines.
    // Screen coordinate -> game coordinate is (coord * 4) / 9.
    wire       in_window = (hcnt >= 12'd240) && (hcnt < 12'd1680);
    // Scale by 4/9 (the 2.25x) with distributed-ROM lookup tables.  Arithmetic
    // is the wrong tool here: a divider missed the pixel clock by 3.2 ns and a
    // DSP48 multiplier by the same amount, because the renderer+palette+packer
    // chain already consumes nearly the whole 6.73 ns budget.  An async LUT ROM
    // costs ~2 levels instead of 20.
    wire [11:0] sxc = hcnt[11:0] - 12'd240;             // 0..1439 inside the image

    (* rom_style = "distributed" *)
    reg [9:0] gx_map [0:1439];
    (* rom_style = "distributed" *)
    reg [9:0] gy_map [0:1079];
    integer mi;
    initial begin
        for (mi = 0; mi < 1440; mi = mi + 1)
            gx_map[mi] = (mi * 4) / 9;                  // 0..639
        for (mi = 0; mi < 1080; mi = mi + 1)
            gy_map[mi] = (mi * 4) / 9;                  // 0..479 (1080 -> 480, clamped below)
    end

    wire [9:0] gx   = gx_map[sxc];
    wire [9:0] gy_r = gy_map[vcnt[10:0]];
    wire [9:0] gy   = (gy_r > 10'd479) ? 10'd479 : gy_r;   // clamp the last line

    // ------------------------------------------------------------------ render
    wire [4:0] pidx;
    render_flappy u_render (
        .x(gx), .y(gy),
        .state(state), .bird_y(bird_y), .bird_frame(bird_frame),
        .score_h(score_h), .score_t(score_t), .score_o(score_o),
        .hi_h(hi_h), .hi_t(hi_t), .hi_o(hi_o),
        .show_score(show_score),
        .pipe_x0(pipe_x0), .pipe_x1(pipe_x1), .pipe_x2(pipe_x2),
        .gap0(gap0), .gap1(gap1), .gap2(gap2),
        .scroll(scroll),
        .pidx(pidx)
    );

    // ------------------------------------------------------ bring-up test image
    // COLOUR_BARS = 1'b1 draws eight equal vertical bands: a pure luma ramp
    // (0 -> 255) with neutral chroma (Cb = Cr = 128).  Combined with the
    // identity colour-space matrix this shows which physical output channel
    // the FPGA's luma byte reaches: on correct wiring the ramp appears in the
    // green channel; any other hue means the channels are permuted.
    // COLOUR_BARS = 1'b0 runs the game.
    localparam COLOUR_BARS = 1'b0;

    wire [3:0] band = (hcnt < 12'd240)  ? 4'd0 : (hcnt < 12'd480)  ? 4'd1 :
                      (hcnt < 12'd720)  ? 4'd2 : (hcnt < 12'd960)  ? 4'd3 :
                      (hcnt < 12'd1200) ? 4'd4 : (hcnt < 12'd1440) ? 4'd5 :
                      (hcnt < 12'd1680) ? 4'd6 : 4'd7;

    reg [7:0] bar_y, bar_cb, bar_cr;
    always @(*) begin
        bar_cb = 8'd128;                       // neutral chroma
        bar_cr = 8'd128;
        case (band)
        4'd0:    bar_y = 8'd0;
        4'd1:    bar_y = 8'd36;
        4'd2:    bar_y = 8'd73;
        4'd3:    bar_y = 8'd109;
        4'd4:    bar_y = 8'd146;
        4'd5:    bar_y = 8'd182;
        4'd6:    bar_y = 8'd219;
        default: bar_y = 8'd255;
        endcase
    end

    wire [7:0] pal_y, pal_cb, pal_cr;
    gfx_palette u_pal (.idx(pidx), .y(pal_y), .cb(pal_cb), .cr(pal_cr));

    wire [7:0] pix_y  = COLOUR_BARS ? bar_y  : (in_window ? pal_y  : 8'd16);
    wire [7:0] pix_cb = COLOUR_BARS ? bar_cb : (in_window ? pal_cb : 8'd128);
    wire [7:0] pix_cr = COLOUR_BARS ? bar_cr : (in_window ? pal_cr : 8'd128);

    // -------------------------------------------------- YCbCr 4:2:2 packing
    wire [15:0] vid_d;
    wire        vid_de, vid_hs, vid_vs;
    ycbcr422_pack u_pack (
        .clk(clk25), .rst(rst),
        .de(de), .hsync(hs), .vsync(vs), .hcnt(hcnt[9:0]),
        .pix_y(pix_y), .pix_cb(pix_cb), .pix_cr(pix_cr),
        .vid_d(vid_d), .vid_de(vid_de), .vid_hs(vid_hs), .vid_vs(vid_vs)
    );

    assign HDMI_D[15:0]  = vid_d;
    assign HDMI_D[17:16] = 2'b00;                    // unused in 16-bit mode
    assign HDMI_DE       = vid_de;
    assign HDMI_HSYNC    = vid_hs;
    assign HDMI_VSYNC    = vid_vs;

    // Pixel clock out, inverted with respect to the data registers so that the
    // ADV7511 samples each bit in the middle of its eye.
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr_clk (
        .Q  (HDMI_CLK),
        .C  (clk25),
        .CE (1'b1),
        .D1 (1'b0),
        .D2 (1'b1),
        .R  (1'b0),
        .S  (1'b0)
    );

    // ---------------------------------------------------------------- I2C bus
    assign IIC_MUX_RESET_B = 1'b1;                   // release the PCA9548 reset

    wire scl_oe, sda_oe, sda_i;
    // open drain on both lines: drive 0, or release and let the board pull-ups
    // raise the line
    // CAUTION: the Xilinx primitives use T as *tri-state* control -- T = 1
    // disables the output (Hi-Z), T = 0 drives it.  The master's *_oe signals
    // mean the opposite: oe = 1 requests "pull the line low", oe = 0 releases
    // it (see the S_START/S_ACK1 branches in i2c_master.v).  Driving T straight
    // from oe therefore inverts both bus lines: SCL comes out as an inverted
    // clock and SDA is held low exactly when it should float.  On hardware that
    // made every transfer look ACKed (the master read back its own low) and
    // every register read return 0x00, while the slave never saw a valid START.
    // The module-level testbenches cannot catch this: they model the bus at the
    // oe ports, where the intended convention already holds.
    OBUFT u_scl (.O(IIC_SCL_MAIN), .I(1'b0), .T(~scl_oe));
    IOBUF u_sda (.IO(IIC_SDA_MAIN), .I(1'b0), .T(~sda_oe), .O(sda_i));

    wire       init_done, init_err, i2c_busy, i2c_done, i2c_err;
    wire       init_start, init_nbytes;
    wire [6:0] init_dev;
    wire [15:0] init_wdata;
    wire [7:0]  i2c_rdata;
    // status poller: reads the ADV7511's 0x42 register once the init has run
    wire       st_start, st_rd, hpd, sense, rd_err, hpd_rise;
    wire       pll_lock;
    wire [7:0] d6_rb;
    wire [6:0] st_dev;
    wire [15:0] st_wdata;

    // ------------------------------------------------- colour-mapping sweeper
    // Diagnostic aid: SW5 advances the transmitter's input-mapping setting so
    // the whole style x alignment space can be walked on the bench without
    // rebuilding a bitstream per candidate.  Each press writes two bytes,
    // 0x16 (input style) and 0x48 (4:2:2 alignment); the low four LEDs show
    // the current index.  Nine combinations: 3 styles x 3 alignments.
    localparam [3:0] SWEEP_N = 4'd9;

    reg  [3:0]  sweep_idx;
    reg  [2:0]  sweep_ph;          // 0 idle, 1-2 write 0x16, 3-4 write 0x48
    reg         sweep_go;          // holds the bus mux while a sweep write runs
    reg         sweep_start;
    reg  [15:0] sweep_wdata;

    wire [7:0]  sweep_style = (sweep_idx < 4'd3) ? 8'h38 :      // style 1
                              (sweep_idx < 4'd6) ? 8'h34 :      // style 2
                                                   8'h3C;       // style 3
    wire [7:0]  sweep_align = ((sweep_idx % 4'd3) == 4'd1) ? 8'h08 :   // right
                              ((sweep_idx % 4'd3) == 4'd2) ? 8'h10 :   // left
                                                             8'h00;    // evenly

    always @(posedge clk25) begin
        if (rst) begin
            sweep_idx   <= 4'd0;
            sweep_ph    <= 3'd0;
            sweep_go    <= 1'b0;
            sweep_start <= 1'b0;
            sweep_wdata <= 16'h0;
        end else begin
            sweep_start <= 1'b0;
            case (sweep_ph)
            3'd0: if (COLOUR_BARS && flap && init_done) begin
                      sweep_idx <= (sweep_idx == SWEEP_N - 4'd1) ? 4'd0
                                                                 : sweep_idx + 4'd1;
                      sweep_go  <= 1'b1;
                      sweep_ph  <= 3'd1;
                  end
            3'd1: if (!i2c_busy) begin                   // wait for a free bus
                      sweep_start <= 1'b1;
                      sweep_wdata <= {8'h16, sweep_style};
                      sweep_ph    <= 3'd2;
                  end
            3'd2: if (i2c_done | i2c_err) sweep_ph <= 3'd3;
            3'd3: if (!i2c_busy) begin
                      sweep_start <= 1'b1;
                      sweep_wdata <= {8'h48, sweep_align};
                      sweep_ph    <= 3'd4;
                  end
            3'd4: if (i2c_done | i2c_err) begin
                      sweep_ph <= 3'd0;
                      sweep_go <= 1'b0;
                  end
            default: sweep_ph <= 3'd0;
            endcase
        end
    end

    // The I2C master command lines belong to the init sequencer until it is
    // finished, to the colour-mapping sweeper while a sweep write is pending,
    // and to the status poller otherwise.  A restart drops init_done, which
    // hands the bus straight back to the sequencer.
    wire        poll      = init_done;
    wire        i2c_start  = poll ? (sweep_go ? sweep_start : st_start) : init_start;
    wire        i2c_rd     = poll ? (sweep_go ? 1'b0        : st_rd)    : 1'b0;
    wire [6:0]  i2c_dev    = poll ? (sweep_go ? 7'h39       : st_dev)   : init_dev;
    wire [15:0] i2c_wdata  = poll ? (sweep_go ? sweep_wdata : st_wdata) : init_wdata;
    wire        i2c_nbytes = poll ? (sweep_go ? 1'b0        : 1'b1)     : init_nbytes;

    adv7511_init u_init (
        .clk(clk25), .rst(rst), .restart(hpd_rise),
        .i2c_start(init_start), .i2c_dev(init_dev),
        .i2c_wdata(init_wdata), .i2c_nbytes(init_nbytes),
        .i2c_busy(i2c_busy), .i2c_done(i2c_done), .i2c_err(i2c_err),
        .init_done(init_done), .err_latch(init_err)
    );

    adv7511_status u_status (
        .clk(clk25), .rst(rst), .enable(init_done),
        .i2c_start(st_start), .i2c_rd(st_rd), .i2c_dev(st_dev),
        .i2c_wdata(st_wdata),
        .i2c_busy(i2c_busy), .i2c_done(i2c_done), .i2c_err(i2c_err),
        .i2c_rdata(i2c_rdata),
        .hpd(hpd), .sense(sense), .pll_lock(pll_lock), .d6_rb(d6_rb),
        .rd_err(rd_err), .hpd_rise(hpd_rise)
    );

    i2c_master #(.CLK_HZ(CLK_HZ), .SCL_HZ(100_000)) u_i2c (
        .clk(clk25), .rst(rst),
        .start(i2c_start), .dev(i2c_dev),
        .nbytes(i2c_nbytes), .rd(i2c_rd), .wdata(i2c_wdata),
        .rdata(i2c_rdata),
        .busy(i2c_busy), .done(i2c_done), .err(i2c_err),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_i(sda_i)
    );

    // -------------------------------------------------------- LED diagnostics
    // The user LEDs are the only hardware-visible debug channel on this board,
    // so they report the HDMI bring-up state instead of being decorative:
    //   LED0 (DS4)  = MMCM locked                     (the 200 MHz clock arrived)
    //   LED1 (DS1)  = ADV7511 configuration complete  (every I2C write was ACKed)
    //   LED2 (DS10) = monitor sense, register 0x42[5] (transmitter sees the
    //                                                   sink's TMDS termination)
    //   LED3 (DS2)  = HPD state, register 0x42[6]     (sink asserts hot plug)
    // If an I2C read fails, LED2 and LED3 alternate at ~1.5 Hz instead.  They
    // share bank 33 with the system clock, so the XDC waives Vivado's BIVC
    // bank-voltage check for that bank.
    reg [26:0] st_blink;
    always @(posedge clk25)
        st_blink <= st_blink + 27'd1;

    wire st_flash = st_blink[26];                    // ~1.1 Hz at 148.5 MHz

    // In the colour-bar diagnostic build the low four LEDs show the sweeper's
    // current combination (binary, 0-8); the high four keep their status
    // meaning.  With the game running they revert to the bring-up lamps.
    assign GPIO_LED_0 = COLOUR_BARS ? sweep_idx[0] : locked;
    assign GPIO_LED_1 = COLOUR_BARS ? sweep_idx[1] : init_done;
    assign GPIO_LED_2 = COLOUR_BARS ? sweep_idx[2] : sense;
    assign GPIO_LED_3 = COLOUR_BARS ? sweep_idx[3] : hpd;
    assign GPIO_LED_4 = d6_rb[7];                    // 0xD6 read-back, expect 1
    assign GPIO_LED_5 = d6_rb[6];                    // 0xD6 read-back, expect 1
    assign GPIO_LED_6 = pll_lock;                    // 0x9E[4] input PLL lock
    assign GPIO_LED_7 = rd_err;                      // any I2C NACK

endmodule
