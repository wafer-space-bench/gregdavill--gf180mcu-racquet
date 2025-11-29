module racquet (
    input logic clk,
    input logic rst_n,

    // SPI pins
    output logic sck,
    output logic copi,
    input  logic cipo,
    output logic cs,

    // Loader interface
    output logic [7:0] o_loader_payload,
    output logic       o_loader_valid,
    input  logic       i_loader_ready,

    output logic loader_enabled
);

    // Instantiate SPI module
    // spi expects cmd/resp valid/ready and fields
    logic cmd_valid, cmd_ready;
    logic        cmd_chip;
    logic [31:0] cmd_data;
    logic [ 5:0] cmd_bits;

    logic resp_valid, resp_ready;
    logic [31:0] resp_data;

    logic [ 7:0] divisor;

    assign divisor = 8'd2;

    spi u_spi (
        .clk  (clk),
        .rst_n(rst_n),

        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd_chip (cmd_chip),
        .cmd_data (cmd_data),
        .cmd_bits (cmd_bits),

        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .resp_data (resp_data),

        .divisor(divisor),

        .sck (sck),
        .copi(copi),
        .cipo(cipo),
        .cs  (cs)
    );

    // Internal registers/counters
    logic [10:0] next_counter;
    logic [10:0] counter;
    logic [15:0] preamble;
    logic [ 7:0] opcode;
    logic [ 7:0] opcode_reg;

    // On response handshake, capture low byte into opcode_reg
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            opcode_reg <= 8'd0;
        end else begin
            if (resp_ready && resp_valid) begin
                opcode_reg <= resp_data[7:0];
            end
        end
    end

    // FSM
    typedef enum logic [2:0] {
        S_RESET,
        S_ADDR,
        S_PREAMBLE_WAIT,
        S_OPCODE_LOOP,
        S_LOAD,
        S_DONE,
        S_FIN
    } state_t;
    state_t state, next_state;

    // FSM state
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_RESET;
            counter <= '0;
        end else begin
            state   <= next_state;
            counter <= next_counter;
        end
    end

    assign opcode = {resp_data[7:0]};
    assign preamble = {opcode_reg, resp_data[7:0]};
    assign loader_enabled = state != S_FIN;

    assign o_loader_payload = resp_data[7:0];
    assign o_loader_valid = (state == S_LOAD) && resp_valid;


    always_comb begin
        next_state   = state;
        next_counter = counter;

        case (state)
            S_RESET: begin
                next_state = S_ADDR;
            end

            S_ADDR: begin
                if (cmd_ready) begin
                    next_counter = 11'd128;
                    next_state   = S_PREAMBLE_WAIT;
                end
            end

            S_PREAMBLE_WAIT: begin
                if (resp_valid) begin
                    next_counter = counter - 1;
                    if (preamble == 16'hcafe) begin
                        next_state = S_OPCODE_LOOP;
                    end else if (counter == 0) begin
                        next_state = S_DONE;
                    end
                end
            end

            S_OPCODE_LOOP: begin
                if (resp_valid) begin
                    case (opcode_reg)
                        8'h00, 8'hFF: begin
                            // NOP
                        end
                        8'h10: begin  // LOAD
                            next_state   = S_LOAD;
                            next_counter = 11'd511;
                        end
                        8'h11: begin  // DONE
                            next_state = S_DONE;
                        end
                        default: begin
                            // ignore
                        end
                    endcase
                end
            end

            S_DONE: begin
                if (cmd_ready) begin
                    next_state = S_FIN;
                end
            end


            S_LOAD: begin
                if (i_loader_ready && resp_valid) begin
                    next_counter = counter - 1;
                    if (counter == 0) begin
                        next_state = S_OPCODE_LOOP;
                    end
                end
            end

            default: begin

            end

        endcase
    end


    always_comb begin
        // defaults
        cmd_valid  = 1'b0;
        cmd_chip   = 1'b0;
        cmd_data   = 32'd0;
        cmd_bits   = 6'd0;

        resp_ready = 1'b0;

        case (state)
            S_ADDR: begin
                cmd_valid = 1'b1;
                cmd_data  = 32'h03_000000;
                cmd_bits  = 6'd32;
                cmd_chip  = 1'b1;
            end

            S_PREAMBLE_WAIT: begin
                cmd_valid  = 1'b1;
                cmd_bits   = 6'd8;
                cmd_data   = 32'd0;
                cmd_chip   = 1'b1;

                resp_ready = 1'b1;
            end

            S_OPCODE_LOOP: begin
                cmd_valid  = 1'b1;
                cmd_bits   = 6'd8;
                cmd_data   = 32'd0;
                cmd_chip   = 1'b1;

                resp_ready = 1'b1;
            end

            S_DONE: begin
                cmd_valid  = 1'b1;
                cmd_data   = 32'd0;
                cmd_bits   = 6'd0;
                cmd_chip   = 1'b0;

                resp_ready = 1'b1;
            end

            S_FIN: begin
                resp_ready = 1'b1;
            end

            S_LOAD: begin
                cmd_valid = 1'b1;
                cmd_bits  = 6'd8;
                cmd_data  = 32'd0;
                cmd_chip  = 1'b1;

                if (i_loader_ready && resp_valid) begin
                    resp_ready = 1'b1;
                end
            end

            default: begin
            end

        endcase
    end


endmodule
