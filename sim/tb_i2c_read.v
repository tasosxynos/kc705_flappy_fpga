// ============================================================================
//  tb_i2c_read.v -- verifies the register-read path of i2c_master.
//
//  The master is asked for a single-byte read of register 0x42 from device
//  0x39, which must appear on the bus as
//      START, 0x72 (39+W), 0x42 (index), <repeated START>, 0x73 (39+R),
//      <one data byte driven by the slave>, NACK from the master, STOP
//  and must hand the slave's byte back on rdata.
//
//  The slave model drives 0x68 (= HPD high, monitor sense high) and records
//  what it saw, so a wrong address, a missing repeated START or a master that
//  forgets to NACK all show up as failures.
// ============================================================================
`timescale 1ns / 1ps

module tb_i2c_read;

    integer fails = 0;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #20 clk = ~clk;              // 25 MHz

    // ---------------------------------------------------------------- master
    reg         start  = 1'b0;
    reg         rd     = 1'b1;
    reg  [6:0]  dev    = 7'h39;
    reg         nbytes = 1'b1;
    reg  [15:0] wdata  = 16'h42_00;     // byte1 = register index
    wire        busy, done, err;
    wire [7:0]  rdata;
    wire        scl_oe, sda_oe, sda_i;

    i2c_master #(.CLK_HZ(25_000_000), .SCL_HZ(100_000)) u_master (
        .clk(clk), .rst(rst),
        .start(start), .dev(dev), .nbytes(nbytes), .rd(rd), .wdata(wdata),
        .rdata(rdata), .busy(busy), .done(done), .err(err),
        .scl_oe(scl_oe), .sda_oe(sda_oe), .sda_i(sda_i)
    );

    // ------------------------------------------------------------- state trace
    // 0 idle 1 start 2 addr 3 ack1 4 data1 5 ack2 6 data2 7 ack3 8 stop 9 end
    // 10 restart 11 addr+R 12 ack+R 13 read data 14 nack
    reg [3:0] pstate = 4'hF;
    always @(posedge clk) begin
        if (u_master.state !== pstate) begin
            $display("  [%0t] master state -> %0d", $time, u_master.state);
            pstate <= u_master.state;
        end
    end

    // ------------------------------------------------------------- open drain
    reg  slave_low = 1'b0;
    wire scl = scl_oe ? 1'b0 : 1'bz;
    wire sda = (sda_oe || slave_low) ? 1'b0 : 1'bz;
    pullup p_scl (scl);
    pullup p_sda (sda);
    assign sda_i = sda;

    // ------------------------------------------------- behavioural I2C slave
    localparam [7:0] REG_VAL = 8'h68;   // HPD = 1, monitor sense = 1

    reg        scl_d = 1'b1, sda_d = 1'b1;
    always @(posedge clk) begin
        scl_d <= scl;
        sda_d <= sda;
    end
    wire start_ev =  scl_d &&  sda_d && !sda;    // START / repeated START
    wire stop_ev  =  scl_d && !sda_d &&  sda;    // STOP
    wire scl_rise = !scl_d &&  scl;
    wire scl_fall =  scl_d && !scl;

    reg [3:0] bitn  = 4'd0;     // bit counter inside a byte (0..8, 8 = ack slot)
    reg [2:0] phase = 3'd0;     // 0 addr+W, 1 register index, 2 addr+R, 3 read data
    reg [7:0] sh    = 8'h00;
    reg [7:0] txd   = 8'h00;

    reg [7:0] seen_addr_w = 8'h00, seen_reg = 8'h00, seen_addr_r = 8'h00;
    integer   n_start = 0, n_stop = 0;
    reg       master_nack = 1'b0;

    always @(posedge clk) begin
        if (start_ev) begin
            n_start <= n_start + 1;
            bitn    <= 4'd0;
            phase   <= (phase == 3'd1) ? 3'd2 : 3'd0;
            slave_low <= 1'b0;
        end else if (stop_ev) begin
            n_stop <= n_stop + 1;
            slave_low <= 1'b0;
        end else if (scl_rise) begin
            if (phase == 3'd3) begin
                if (bitn == 4'd8) master_nack <= sda;   // ninth clock: expect high
            end else if (bitn < 4'd8) begin
                sh <= {sh[6:0], sda};
            end
            bitn <= bitn + 4'd1;
        end else if (scl_fall) begin
            if (phase == 3'd3) begin
                if (bitn < 4'd8) begin
                    slave_low <= ~txd[7];               // drive the next data bit
                    txd <= {txd[6:0], 1'b0};
                end else begin
                    slave_low <= 1'b0;                  // release for the NACK
                end
            end else if (bitn >= 4'd9) begin
                // eight data bits plus the ACK slot are complete
                slave_low <= 1'b0;
                bitn      <= 4'd0;
                case (phase)
                3'd0: begin seen_addr_w <= sh; phase <= 3'd1; $display("  [%0t] slave: byte addr+W = %02x", $time, sh); end
                3'd1: begin seen_reg    <= sh; $display("  [%0t] slave: byte index  = %02x", $time, sh); end
                3'd2: begin
                    seen_addr_r <= sh;
                    phase <= 3'd3;
                    txd   <= {REG_VAL[6:0], 1'b0};
                    slave_low <= ~REG_VAL[7];           // first read bit
                end
                default: ;
                endcase
            end else if (bitn == 4'd8) begin
                slave_low <= 1'b1;                      // ACK slot: pull SDA low
            end
        end
    end

    // ------------------------------------------------------------- test body
    initial begin
        #200 rst = 1'b0;
        repeat (20) @(posedge clk);

        if (busy) begin
            $display("FAIL: master busy before any command");
            fails = fails + 1;
        end

        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        repeat (10) @(posedge clk);

        $display("bus decode: addr+W = %02x, index = %02x, addr+R = %02x",
                 seen_addr_w, seen_reg, seen_addr_r);
        $display("            starts = %0d, stops = %0d, master NACK = %0d, rdata = %02x",
                 n_start, n_stop, master_nack, rdata);

        if (seen_addr_w !== 8'h72) begin
            $display("FAIL: address+W was %02x, expected 72 (39 << 1 | 0)", seen_addr_w);
            fails = fails + 1;
        end
        if (seen_reg !== 8'h42) begin
            $display("FAIL: register index was %02x, expected 42", seen_reg);
            fails = fails + 1;
        end
        if (seen_addr_r !== 8'h73) begin
            $display("FAIL: address+R was %02x, expected 73 (39 << 1 | 1)", seen_addr_r);
            fails = fails + 1;
        end
        if (n_start !== 2) begin
            $display("FAIL: saw %0d starts, expected 2 (START + repeated START)", n_start);
            fails = fails + 1;
        end
        if (n_stop !== 1) begin
            $display("FAIL: saw %0d stops, expected 1", n_stop);
            fails = fails + 1;
        end
        if (!master_nack) begin
            $display("FAIL: master did not NACK the last read byte");
            fails = fails + 1;
        end
        if (rdata !== REG_VAL) begin
            $display("FAIL: rdata = %02x, expected %02x", rdata, REG_VAL);
            fails = fails + 1;
        end
        if (err) begin
            $display("FAIL: master flagged a NACK error");
            fails = fails + 1;
        end

        if (fails == 0)
            $display("TEST PASSED: single-byte register read is correct");
        else
            $display("TEST FAILED: %0d check(s) failed", fails);
        $finish;
    end

endmodule
