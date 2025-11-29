// SPI controller translated from Amaranth Python to SystemVerilog
// - cmd: input handshake struct {chip:1, data:32, bits:6}
// - resp: output handshake struct {data:32}
// - divisor: input (8-bit) controls SCK frequency: toggles every divisor cycles
// - sck: output
// - copi: output (MOSI)
// - cipo: input  (MISO)
// - cs: output (active low), default 1 (deasserted)

module spi (
    input logic clk,
    input logic rst_n,

    // cmd handshake
    input  logic        cmd_valid,
    output logic        cmd_ready,
    input  logic [ 0:0] cmd_chip,
    input  logic [31:0] cmd_data,
    input  logic [ 5:0] cmd_bits,

    // resp handshake
    output logic        resp_valid,
    input  logic        resp_ready,
    output logic [31:0] resp_data,

    // divisor: 8-bit (use lower 8 bits)
    input logic [7:0] divisor,

    // SPI pins
    output logic sck,
    output logic copi,  // MOSI
    input  logic cipo,  // MISO
    output logic cs
);

    // Internal signals
    logic [ 8:0] sck_div;  // enough to hold (divisor<<1)-1 up to 512
    logic        sck_phase;  // combinational phase (0/1)
    logic        sck_reg;  // registered sck output

    logic        idle;

    logic [ 5:0] bit_index;
    logic [31:0] tx_shift;
    logic [31:0] rx_shift;

    // Default outputs
    assign resp_data = rx_shift;

    // sck and copi are driven combinationally from registers
    assign copi = tx_shift[31];
    assign sck = sck_reg;

    // Divider and phase logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_div <= 9'd1;
        end else begin
            if (!idle) begin
                if (sck_div == 0) sck_div <= ({1'b0, divisor} << 1) - 1;
                else sck_div <= sck_div - 1;
            end else begin
                sck_div <= 9'd1;
            end
        end
    end

    always_comb begin
        // phase high when sck_div >= divisor
        sck_phase = (sck_div >= {1'b0, divisor});
        sck_reg   = sck_phase;
    end

    // FSM states
    typedef enum logic [1:0] {
        S_IDLE,
        S_SHIFT,
        S_RESP
    } state_t;
    state_t state, next_state;

    // Synchronous FSM and registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // FSM next state logic
    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (cmd_valid && cmd_ready)
                    if (cmd_bits > 6'd0) next_state = S_SHIFT;
            end

            S_SHIFT: begin
                if (sck_div == (({1'b0, divisor} << 1) - 2))
                    if (bit_index == 6'd0) next_state = S_RESP;
            end

            S_RESP: begin
                if (resp_valid && resp_ready) next_state = S_IDLE;
            end

            default: begin
            end
        endcase
    end

    // Synchronous logic from FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift <= '0;
            rx_shift <= '0;
            bit_index <= '0;
            cs <= 1'b1;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid && cmd_ready) begin
                        bit_index <= (cmd_bits == 6'd0) ? 6'd0 : (cmd_bits - 1);
                        tx_shift <= cmd_data;
                        cs <= ~cmd_chip;  // assert CS (active low)
                    end
                end

                S_SHIFT: begin
                    if (sck_div == {1'b0, divisor}) begin
                        tx_shift <= {
                            tx_shift[30:0], 1'b0
                        };  // shift right with 0 into LSB, keep MSB at bit 31
                    end

                    if (sck_div == (({1'b0, divisor} << 1) - 2)) begin

                        rx_shift <= {rx_shift[30:0], cipo};
                        if (bit_index != 6'd0) begin
                            bit_index <= bit_index - 1;
                        end
                    end
                end

                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_ready <= 1'b1;
            resp_valid <= 1'b0;
            idle <= 1'b1;
        end else begin
            case (next_state)
                S_IDLE: begin
                    idle <= 1'b1;
                    cmd_ready <= 1'b1;
                    resp_valid <= 1'b0;
                end

                S_SHIFT: begin
                    idle <= 1'b0;
                    cmd_ready <= 1'b0;
                end

                S_RESP: begin
                    resp_valid <= 1'b1;
                end

                default: begin
                end
            endcase
        end
    end

endmodule
