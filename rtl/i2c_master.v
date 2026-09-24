// ============================================================================
//  i2c_master.v -- minimal I2C master (write-only, open-drain outputs).
//
//  Transfer format:  START, <dev>+W, <byte1>, [<byte2>], STOP
//      nbytes = 1 : send byte1 only          (single command byte, PCA9548)
//      nbytes = 0 : send byte1 then byte2    (register index + value)
//
//  rd = 1 selects a single-byte register read instead:
//      START, <dev>+W, <byte1 = register index>, <restart>, <dev>+R,
//      <read one byte into rdata>, NACK, STOP
//  wdata = {byte1, byte2}, byte1 is sent first.
//
//  Bus pins are open drain: *_oe = 1 pulls the line LOW, *_oe = 0 releases it
//  (external pull-ups raise it).  A NACK from a slave is latched into err and
//  cleared at the start of the next transfer.
// ============================================================================
`timescale 1ns / 1ps

module i2c_master #(
    parameter CLK_HZ = 25_000_000,
    parameter SCL_HZ = 100_000
) (
    input  wire        clk,
    input  wire        rst,
    // command interface
    input  wire        start,
    input  wire [6:0]  dev,        // 7-bit device address
    input  wire        nbytes,     // 1 = one data byte, 0 = two data bytes
    input  wire        rd,         // 1 = single-byte register read (see above)
    input  wire [15:0] wdata,      // {byte1, byte2}
    output reg  [7:0]  rdata,      // byte read back by the rd transaction
    output reg         busy,
    output reg         done,       // 1-cycle pulse when the transfer finishes
    output reg         err,        // sticky NACK flag
    // I2C bus (open drain)
    output reg         scl_oe,     // 1 = drive SCL low
    output reg         sda_oe,     // 1 = drive SDA low
    input  wire        sda_i       // SDA line state (ACK sampling)
);

    localparam QT = (CLK_HZ / (SCL_HZ * 4)) > 1 ? (CLK_HZ / (SCL_HZ * 4)) : 1;

    localparam S_IDLE  = 4'd0,
               S_START = 4'd1,
               S_ADDR  = 4'd2,
               S_ACK1  = 4'd3,
               S_DATA1 = 4'd4,
               S_ACK2  = 4'd5,
               S_DATA2 = 4'd6,
               S_ACK3  = 4'd7,
               S_STOP  = 4'd8,
               S_END   = 4'd9,
               S_RSTART = 4'd10,   // repeated START before the read address
               S_RADDR  = 4'd11,   // address byte with R/W = 1
               S_RACK   = 4'd12,   // ACK slot after the read address
               S_RDATA  = 4'd13,   // shift in the read byte
               S_NACK   = 4'd14;   // master NACK to end the read

    reg [3:0]  state;
    reg [15:0] qc;         // quarter-tick counter
    reg [1:0]  ph;         // phase inside a bit (0..3)
    reg [2:0]  bitc;       // bit index, 7 down to 0
    reg [15:0] sh;         // bytes to send, held stable for the whole transfer
    reg [7:0]  cur;        // byte currently being shifted out (MSB first)
    reg        two;        // send two data bytes
    reg        rdm;        // transaction is a register read

    wire       qtick   = (qc == QT[15:0] - 16'd1);
    wire       ph_last = (ph == 2'd3);

    always @(posedge clk) begin
        if (rst) begin
            qc     <= 16'd0;
            ph     <= 2'd0;
            state  <= S_IDLE;
            busy   <= 1'b0;
            done   <= 1'b0;
            err    <= 1'b0;
            scl_oe <= 1'b0;        // bus released (high) = idle
            sda_oe <= 1'b0;
            bitc   <= 3'd7;
            sh     <= 16'd0;
            cur    <= 8'h00;
            two    <= 1'b1;
            rdm    <= 1'b0;
            rdata  <= 8'h00;
        end else begin
            done <= 1'b0;

            if (qtick) begin
                qc <= 16'd0;
                ph <= ph_last ? 2'd0 : ph + 2'd1;
            end else begin
                qc <= qc + 16'd1;
            end

            case (state)
            // ------------------------------------------------------------------
            S_IDLE: begin
                scl_oe <= 1'b0;
                sda_oe <= 1'b0;
                busy   <= 1'b0;
                if (start) begin
                    busy  <= 1'b1;
                    err   <= 1'b0;
                    sh    <= wdata;
                    two   <= ~nbytes;
                    rdm   <= rd ? 1'b1 : 1'b0;
                    bitc  <= 3'd7;
                    ph    <= 2'd0;
                    state <= S_START;
                end
            end
            // ------------------------------------------------------------------
            // START condition: SDA falls while SCL is high
            S_START: begin
                if (qtick) begin
                    case (ph)
                    2'd0: begin
                        scl_oe <= 1'b0;      // SCL high (already high)
                        sda_oe <= 1'b1;      // SDA low -> START
                    end
                    2'd2: scl_oe <= 1'b1;    // SCL low; SDA stays low
                    2'd3: begin
                        state <= S_ADDR;
                        cur   <= {dev, 1'b0}; // address byte, R/W = 0 (write)
                        bitc  <= 3'd7;
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            // address and data bytes, MSB first
            S_ADDR, S_DATA1, S_DATA2, S_RADDR: begin
                if (qtick) begin
                    case (ph)
                    2'd0: sda_oe <= ~cur[7];      // 1 -> pull low, 0 -> release
                    2'd1: scl_oe <= 1'b0;         // SCL high (slave samples)
                    2'd3: begin                   // SCL low, advance
                        scl_oe <= 1'b1;
                        cur    <= {cur[6:0], 1'b0};
                        if (bitc == 3'd0) begin
                            case (state)
                            S_ADDR:  state <= S_ACK1;
                            S_DATA1: state <= S_ACK2;
                            S_RADDR: state <= S_RACK;
                            default: state <= S_ACK3;
                            endcase
                        end else begin
                            bitc <= bitc - 3'd1;
                        end
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            // ACK slot: release SDA, sample it while SCL is high
            S_ACK1, S_ACK2, S_ACK3, S_RACK: begin
                if (qtick) begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;         // let the slave drive ACK
                    2'd1: scl_oe <= 1'b0;         // SCL high
                    2'd2: if (sda_i) err <= 1'b1; // line left high -> NACK
                    2'd3: begin
                        scl_oe <= 1'b1;           // SCL low
                        sda_oe <= 1'b1;
                        bitc   <= 3'd7;
                        case (state)
                        S_ACK1: begin
                            cur   <= sh[15:8];    // first data byte
                            state <= two ? S_DATA1 : S_DATA2;
                        end
                        S_ACK2: begin
                            cur   <= sh[7:0];     // second data byte
                            state <= rdm ? S_RSTART : S_DATA2;
                        end
                        S_RACK: begin
                            cur   <= 8'h00;
                            state <= S_RDATA;
                        end
                        // one-byte transfers send their single data byte through
                        // S_DATA2, so either ACK slot can be the last one -- the
                        // restart for a read has to be issued after both
                        S_ACK3: state <= rdm ? S_RSTART : S_STOP;
                        default: state <= S_STOP;
                        endcase
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            // repeated START ahead of the read address: SDA rises while SCL is
            // low, SCL is raised, then SDA falls again with SCL high
            S_RSTART: begin
                if (qtick) begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;      // release SDA (SCL low)
                    2'd1: scl_oe <= 1'b0;      // SCL high
                    2'd2: sda_oe <= 1'b1;      // SDA low while SCL high -> restart
                    2'd3: begin
                        scl_oe <= 1'b1;        // SCL low
                        cur    <= {dev, 1'b1}; // address byte, R/W = 1 (read)
                        bitc   <= 3'd7;
                        state  <= S_RADDR;
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            // read byte: release SDA and sample it while SCL is high, MSB first
            S_RDATA: begin
                if (qtick) begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;      // slave drives SDA
                    2'd1: scl_oe <= 1'b0;      // SCL high
                    2'd2: rdata  <= {rdata[6:0], sda_i};
                    2'd3: begin
                        scl_oe <= 1'b1;        // SCL low
                        if (bitc == 3'd0) state <= S_NACK;
                        else              bitc  <= bitc - 3'd1;
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            // master NACK on the last read byte (SDA stays released), then STOP
            S_NACK: begin
                if (qtick) begin
                    case (ph)
                    2'd0: sda_oe <= 1'b0;      // leave SDA high -> NACK
                    2'd1: scl_oe <= 1'b0;      // SCL high (9th clock)
                    2'd3: begin
                        scl_oe <= 1'b1;        // SCL low
                        state  <= S_STOP;
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            // STOP condition: SDA rises while SCL is high
            S_STOP: begin
                if (qtick) begin
                    case (ph)
                    2'd0: begin
                        scl_oe <= 1'b1;           // SCL low
                        sda_oe <= 1'b1;           // SDA low
                    end
                    2'd1: scl_oe <= 1'b0;         // SCL high
                    2'd2: sda_oe <= 1'b0;         // SDA high while SCL high -> STOP
                    2'd3: begin
                        scl_oe <= 1'b0;
                        sda_oe <= 1'b0;
                        state  <= S_END;
                    end
                    default: ;
                    endcase
                end
            end
            // ------------------------------------------------------------------
            S_END: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= S_IDLE;
            end
            // ------------------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
