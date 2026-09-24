// ============================================================================
//  tb_i2c_init.v -- verifies the I2C master and the ADV7511 configuration
//  sequence against a behavioural I2C device model.
//
//  The model is an open-drain I2C slave that only acknowledges its own two
//  addresses (0x74 = PCA9548 switch, 0x39 = ADV7511).  That means the test
//  fails if the RTL ever addresses the wrong device -- exactly the bug class
//  that is otherwise invisible without hardware.
//
//  Checked:
//    * the PCA9548 switch is selected first with byte 0x20 (channel 5),
//    * every following transfer goes to 0x39,
//    * the total number of bytes is 1 + 2*40,
//    * the key registers carry the values required for 640x480 16-bit YCbCr
//      4:2:2 input (0x15, 0x16, 0x48, 0xAF, 0xD6, first and last CSC entries),
//    * the master reports no NACK and init_done is raised,
//    * a deliberately un-acknowledged device makes init_done stay low (the
//      retry path) -- checked in the second half of the test.
//
//  Run with:   xsim tb_i2c_init -R
// ============================================================================
`timescale 1ns / 1ps

module tb_i2c_init;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;              // 25 MHz

    // ------------------------------------------------------------ I2C bus
    // Open-drain modelling of the slave: sda is pulled low by the master
    // (sda_oe) or by the device model (ack_low).
    reg        ack_low   = 1'b0;
    reg        ack_ok    = 1'b0;
    reg        is_addr   = 1'b1;
    reg [3:0]  bitn      = 4'd0;
    reg [7:0]  sh        = 8'h00;
    reg [7:0]  cur_addr  = 8'h00;
    reg        nack_mode = 1'b0;      // when 1, the slave never ACKs

    wire scl_oe, sda_oe;                // 1 = pull the line low (open drain)
    wire sda_i;
    wire scl = scl_oe ? 1'b0 : 1'bz;
    // proper wired-AND open-drain model: low if ANY driver pulls low,
    // otherwise high-impedance so the pull-up can raise the line
    wire sda = (sda_oe || ack_low) ? 1'b0 : 1'bz;
    pullup p_scl (scl);
    pullup p_sda (sda);

    assign sda_i = sda;

    // ------------------------------------------------------- DUT: init + master
    wire       start, busy, done, err, init_done, err_latch;
    wire [6:0] dev;
    wire [15:0] wdata;
    wire       nbytes;

    adv7511_init #(
        .POR_CNT  (21'd100),
        .GAP_CNT  (12'd30),
        .RETRY_CNT(20'd500)
    ) u_init (
        .clk(clk), .rst(rst), .restart(1'b0),
        .i2c_start(start), .i2c_dev(dev), .i2c_wdata(wdata), .i2c_nbytes(nbytes),
        .i2c_busy(busy), .i2c_done(done), .i2c_err(err),
        .init_done(init_done), .err_latch(err_latch)
    );

    i2c_master #(.CLK_HZ(25_000_000), .SCL_HZ(100_000)) u_master (
        .clk(clk), .rst(rst),
        .start(start), .dev(dev), .nbytes(nbytes), .rd(1'b0), .wdata(wdata),
        .rdata(), .busy(busy), .done(done), .err(err),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_i(sda_i)
    );

    // -------------------------------------------------- behavioural I2C slave
    localparam [6:0] ADDR_MUX = 7'h74;
    localparam [6:0] ADDR_ADV = 7'h39;

    reg [7:0]  log_addr [0:255];
    reg [7:0]  log_byte [0:255];
    integer    nw = 0;

    wire       sda_in = sda;

    // a START re-arms the address phase
    always @(negedge sda) if (scl) begin
        is_addr <= 1'b1;
        bitn    <= 4'd0;
    end

    always @(posedge scl) begin
        if (bitn < 4'd8) sh <= {sh[6:0], sda_in};
        bitn <= (bitn == 4'd8) ? 4'd0 : (bitn + 4'd1);
    end

    always @(negedge scl) begin
        ack_low <= 1'b0;
        if (bitn == 4'd8) begin
            // the byte has just been shifted in; this is the start of the ACK bit
            if (is_addr) begin
                cur_addr <= sh;
                is_addr  <= 1'b0;
                ack_ok   <= (sh[7:1] == ADDR_MUX) || (sh[7:1] == ADDR_ADV);
                // note: sh is the value that just shifted in, so it can be used
                // directly here (ack_ok from this same edge would be stale)
                ack_low  <= nack_mode ? 1'b0 :
                            ((sh[7:1] == ADDR_MUX) || (sh[7:1] == ADDR_ADV));
            end else begin
                ack_low <= nack_mode ? 1'b0 : ack_ok;
                if (nw < 256) begin
                    log_addr[nw] = cur_addr;
                    log_byte[nw] = sh;
                    nw = nw + 1;
                end
            end
        end
    end

    integer errors = 0;

    // ------------------------------------------------------------------ checks
    integer i, pairs, bad;
    integer mux_bytes, adv_bytes;

    task report_writes;
        begin
            $display("--- I2C traffic captured: %0d data bytes ---", nw);
            for (i = 0; i < nw && i < 12; i = i + 1)
                $display("   [%0d] addr=%h byte=%h", i, log_addr[i], log_byte[i]);
            $display("   ...");
            for (i = (nw > 4 ? nw - 4 : 0); i < nw; i = i + 1)
                $display("   [%0d] addr=%h byte=%h", i, log_addr[i], log_byte[i]);
        end
    endtask

    task check_pair;
        input [5:0] idx;          // register/value pair number (0 = first ADV write)
        input [7:0] r;
        input [7:0] v;
        begin
            if (log_byte[1 + 2*idx] !== r || log_byte[2 + 2*idx] !== v) begin
                $display("ERROR: pair %0d expected %h=%h, got %h=%h", idx, r, v,
                         log_byte[1 + 2*idx], log_byte[2 + 2*idx]);
                errors = errors + 1;
            end else begin
                $display("   ok: %h = %h", r, v);
            end
        end
    endtask

    initial begin
        errors = 0;
        $display("=== tb_i2c_init ===");
        repeat (10) @(posedge clk);
        rst = 1'b0;

        // wait for the configuration sequence to complete
        i = 0;
        while (init_done !== 1'b1 && i < 2000000) begin
            @(posedge clk);
            i = i + 1;
        end

        if (init_done !== 1'b1) begin
            $display("ERROR: init_done never asserted");
            errors = errors + 1;
        end else begin
            $display("init_done after %0d clocks", i);
        end
        if (err_latch !== 1'b0) begin
            $display("ERROR: the master saw a NACK");
            errors = errors + 1;
        end
        if (err !== 1'b0) begin
            $display("ERROR: i2c err is high");
            errors = errors + 1;
        end

        report_writes;

        // --- structure of the traffic ---
        // (log_addr holds the raw address byte, i.e. address<<1 | R/W)
        if (log_addr[0] !== {ADDR_MUX, 1'b0} || log_byte[0] !== 8'h20) begin
            $display("ERROR: the first write must select PCA9548 channel 5 (0x74 <- 0x20), got %h <- %h",
                     log_addr[0], log_byte[0]);
            errors = errors + 1;
        end else begin
            $display("   ok: PCA9548 @0x74 selected with 0x20 (channel 5)");
        end

        // everything after the mux write must target the ADV7511
        bad = 0;
        for (i = 1; i < nw; i = i + 1)
            if (log_addr[i] !== {ADDR_ADV, 1'b0}) bad = bad + 1;
        if (bad != 0) begin
            $display("ERROR: %0d bytes went to an unexpected address", bad);
            errors = errors + 1;
        end else begin
            $display("   ok: all %0d following bytes went to the ADV7511 @0x39", nw - 1);
        end

        // 1 mux byte + 40 register/value pairs
        if (nw != 81) begin
            $display("ERROR: expected 81 data bytes, captured %0d", nw);
            errors = errors + 1;
        end else begin
            $display("   ok: 81 data bytes (1 mux + 40 registers)");
        end

        if (nw == 81) begin
            $display("--- register values ---");
            check_pair( 0, 8'hD6, 8'hC0);   // HPD forced high BEFORE power-up
            check_pair( 1, 8'h41, 8'h10);   // power up
            check_pair( 2, 8'h9A, 8'hE0);
            check_pair( 3, 8'h9C, 8'h30);
            check_pair( 9, 8'h55, 8'h02);
            check_pair(10, 8'h15, 8'h01);   // Input ID 1: 16-bit YCbCr 4:2:2
            check_pair(11, 8'h16, 8'h38);   // style 1, 8-bit, 4:4:4 out
            check_pair(12, 8'h48, 8'h00);
            check_pair(13, 8'hAF, 8'h04);   // DVI mode
            check_pair(14, 8'h98, 8'h03);   // fixed register, parked here
            check_pair(15, 8'h18, 8'hAC);   // CSC enable + A1
            check_pair(37, 8'h2E, 8'h18);   // C4
            check_pair(38, 8'h2F, 8'hBE);   // last CSC entry
            check_pair(39, 8'h41, 8'h10);   // power re-asserted
        end

        // --- second half: a bus that never ACKs must keep init_done low ---
        $display("--- retry path: slave stops acknowledging ---");
        nack_mode = 1'b1;
        @(posedge clk);
        rst = 1'b1;                       // restart the sequencer
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (200000) @(posedge clk);
        if (init_done === 1'b1) begin
            $display("ERROR: init_done asserted although every transfer NACKed");
            errors = errors + 1;
        end else begin
            $display("   ok: init_done stays low and the sequencer keeps retrying");
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

endmodule
