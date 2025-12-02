module wb_uart (
    input logic clk_i,
    input logic rst_n,

    // Control WB port
    input logic        cyc_i,
    input logic        stb_i,
    input logic        we_i,
    input logic [ 3:0] sel_i,
    input logic [11:0] adr_i,
    input logic [31:0] dat_i,

    output logic [31:0] dat_o,
    output logic        ack_o,

    // UART I/O
    output logic tx_o,
    input  logic rx_i
);

    // Register address map, word addresses
    localparam logic [9:0] DATA = 10'h0;
    localparam logic [9:0] DIV = 10'h1;
    localparam logic [9:0] CTRL = 10'h2;
    localparam logic [9:0] STATUS = 10'h3;

    // Registers
    logic [15:0] reg_divisor;
    logic [ 1:0] reg_ctrl;

    logic [ 7:0] tx_data;
    logic        tx_valid;
    logic        tx_ready;

    logic [ 7:0] rx_data;
    logic        rx_valid;
    logic        rx_ready;

    uart_tx u_tx (
        .clk_i(clk_i),
        .rst_n(reg_ctrl[0]),
        .divisor_i(reg_divisor),

        .data_i(tx_data),
        .valid_i(tx_valid),
        .ready_o(tx_ready),
        .tx_o(tx_o)
    );

    uart_rx u_rx (
        .clk_i(clk_i),
        .rst_n(reg_ctrl[1]),
        .divisor_i(reg_divisor),

        .data_o(rx_data),
        .valid_o(rx_valid),
        .ready_i(rx_ready),
        .rx_i(rx_i)
    );

    wire wb_active = cyc_i && stb_i & !ack_o;

    // WB port
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            ack_o <= 1'b0;
            reg_divisor <= 16'd0;
            reg_ctrl <= 2'd0;
        end else begin
            if (wb_active) begin
                ack_o <= 1'b1;
                if (we_i) begin
                    if (adr_i[11:2] == DATA) begin
                        ack_o <= (tx_valid & tx_ready);
                    end

                    if (adr_i[11:2] == DIV) begin
                        for (int b = 0; b < 2; b++) begin  // 16b register
                            if (sel_i[b]) reg_divisor[b*8+:8] <= dat_i[b*8+:8];
                        end
                    end

                    if (adr_i[11:2] == CTRL) begin
                        if (sel_i[0]) begin
                            reg_ctrl[0] <= dat_i[0];  // tx_en
                            reg_ctrl[1] <= dat_i[1];  // rx_en
                        end
                    end
                end else begin
                    // Read ACK generation
                    if (adr_i[11:2] == DATA) begin
                        ack_o <= (rx_valid & rx_ready);
                    end
                end
            end else begin
                ack_o <= 1'b0;
            end
        end
    end


    // dat_o logic
    wire [ 9:0] reg_adr = adr_i[11:2];
    // workaround for iverilog, constant bitselects not supported in always_*
    wire [31:0] div_val = {16'd0, reg_divisor};
    wire [31:0] ctrl_val = {30'd0, reg_ctrl[1], reg_ctrl[0]};
    wire [31:0] status_val = {16'd0, 7'd0, rx_valid, 7'd0, tx_ready};
    always_comb begin
        dat_o = 32'd0;
        case (reg_adr)
            DATA: dat_o = rx_data;
            DIV: dat_o = div_val;
            CTRL: dat_o = ctrl_val;
            STATUS: dat_o = status_val;
            default: dat_o = 32'd0;
        endcase
    end

    assign tx_valid = (wb_active) && (we_i) && (adr_i[11:2] == DATA);
    assign tx_data  = dat_i[7:0];

    assign rx_ready = (wb_active) && (~we_i) && (adr_i[11:2] == DATA);

endmodule



module uart_tx (
    input logic clk_i,
    input logic rst_n,

    input logic [15:0] divisor_i,

    input  logic [7:0] data_i,
    input  logic       valid_i,
    output logic       ready_o,

    output logic tx_o
);

    logic [ 9:0] tx_shift;  // [0] => next bit out; contains start(0), data[7:0], stop(1)
    logic [ 3:0] tx_bits;  // number of bits remaining (0..10)
    logic [15:0] tx_tick;

    // Idle when no bits left
    assign ready_o = (tx_bits == 0);

    // Register tx_o output to aid with timing closure to I/O
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            tx_o <= 1'b1;
        end else begin
            tx_o <= tx_shift[0];
        end
    end

    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift <= 10'h3FF;  // idle high (stop bits)
            tx_bits  <= 4'd0;
            tx_tick  <= 16'd0;
        end else begin
            // start a frame when requested and ready
            if (valid_i && ready_o) begin
                // frame: start bit (0), data LSB first, stop bit (1)
                tx_shift <= {1'b1, data_i, 1'b0};  // MSB first in vector, but we'll shift right
                tx_bits  <= 4'd10;
                tx_tick  <= 16'd0;
            end else if (tx_bits != 0) begin
                if (tx_tick >= divisor_i) begin
                    tx_tick  <= 16'd0;

                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_bits  <= tx_bits - 1;
                end else begin
                    tx_tick <= tx_tick + 1;
                end
            end else begin
                tx_tick <= 16'd0;
            end
        end
    end
endmodule




module uart_rx (
    input logic clk_i,
    input logic rst_n,

    input logic [15:0] divisor_i,

    output logic [7:0] data_o,
    output logic       valid_o,
    input  logic       ready_i,

    input logic rx_i
);

    logic [ 9:0] rx_shift;  // assemble data bits LSB first
    logic [ 3:0] rx_bits;  // 0..9 data bits
    logic [15:0] rx_tick;
    logic        rx_busy;

    logic        shift_valid;

    // Synchronize rx input
    logic [ 1:0] rx_sync;
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync <= 2'b11;
        end else begin
            rx_sync <= {rx_sync[0], rx_i};
        end
    end

    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            rx_shift <= 10'd0;
            rx_bits  <= 4'd0;
            rx_tick  <= 16'd0;
            rx_busy  <= 1'b0;

            valid_o  <= 1'b0;
            data_o   <= 8'd0;
        end else begin

            // data available
            if (valid_o & ready_i) begin
                valid_o <= 1'b0;
            end else if (!rx_busy) begin
                // wait for start bit (falling edge)
                if (~rx_sync[1]) begin
                    rx_busy <= 1'b1;
                    // wait half bit to sample middle of start
                    rx_tick <= (divisor_i >> 1);
                    rx_bits <= 4'd10;
                end
            end else begin
                // in start/bit sampling sequence
                if (rx_bits == 0) begin
                    // check framing
                    if ((rx_shift[0] == 0) && (rx_shift[9] == 1)) begin
                        valid_o <= 1'b1;
                        data_o  <= rx_shift[8:1];
                        rx_busy <= 1'b0;
                        // For simplicity ignore overruns
                    end
                end else begin
                    if (rx_tick >= divisor_i) begin
                        // reached sampling point for start or next bit
                        rx_tick  <= 16'd0;
                        rx_shift <= {rx_sync[1], rx_shift[9:1]};
                        rx_bits  <= rx_bits - 3'd1;
                    end else begin
                        rx_tick <= rx_tick + 1;
                    end
                end
            end
        end
    end

endmodule
