module wb_timer #(
    parameter int TIMER_WIDTH = 32,
    parameter int TIMER_NUM = 4,
    parameter int TIMER_CMP = 4,
    parameter int TIMER_OUTPUTS = 4,
    parameter int TIMER_INPUTS = 4
) (
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

    output logic [TIMER_OUTPUTS-1:0] timer_out,
    input  logic [TIMER_OUTPUTS-1:0] timer_in
);
    // Register address map, word addresses
    localparam logic [9:0] CTRL = 10'h0;
    localparam logic [9:0] STATUS = 10'h1;

    localparam logic [9:0] TIMER0_CTRL0 = 10'h10;
    localparam logic [9:0] TIMER0_CTRL1 = 10'h11;
    localparam logic [9:0] TIMER0_VALUE = 10'h12;
    localparam logic [9:0] TIMER0_CMD = 10'h13;

    localparam logic [9:0] CMP0_CTRL = 10'h80;
    localparam logic [9:0] CMP0_VALUE = 10'h81;
    localparam logic [9:0] CMP0_HCF = 10'h82;

    localparam logic [9:0] OUT0_CTRL = 10'h100;

    localparam logic [9:0] IN0_CTRL = 10'h180;
    localparam logic [9:0] IN0_VALUE = 10'h181;
    localparam logic [9:0] IN0_HCF = 10'h182;

    // Registers
    logic [31:0] reg_timer_ctrl0[TIMER_NUM];
    logic [31:0] reg_timer_ctrl1[TIMER_NUM];

    logic [TIMER_WIDTH-1:0] reg_cmp_value[TIMER_CMP];
    logic [TIMER_WIDTH-1:0] reg_cmp_ctrl[TIMER_CMP];

    logic [15:0] reg_out_ctrl[TIMER_OUTPUTS];
    logic [15:0] reg_in_ctrl[TIMER_INPUTS];

    logic [TIMER_WIDTH-1:0] timer_value[TIMER_NUM];

    logic [TIMER_NUM-1:0] timer_running;
    logic [TIMER_CMP-1:0] cmp_output;
    logic [TIMER_INPUTS-1:0] timer_in_src;

    // output control
    genvar j;
    generate
        for (j = 0; j < TIMER_OUTPUTS; j = j + 1) begin : gen_outputs
            wire [TIMER_CMP-1:0] cmp_inputs = cmp_output[TIMER_CMP-1:0];
            wire [15:0] reg_masked = (reg_out_ctrl[j] & (1 << cmp_inputs));

            always_ff @(posedge clk_i or negedge rst_n) begin
                if (!rst_n) begin
                    timer_out[j] <= 1'b0;
                end else begin
                    timer_out[j] <= |reg_masked;
                end
            end
        end
    endgenerate

    // input control
    generate
        for (j = 0; j < TIMER_INPUTS; j = j + 1) begin : gen_inputs
            wire [7:0] timer_in_mask = reg_in_ctrl[j][15:8];
            wire in_signal = |(timer_in_mask & timer_in);

            logic [2:0] in_sync;
            always_ff @(posedge clk_i or negedge rst_n) begin
                if (!rst_n) begin
                    in_sync <= 3'd0;
                end else begin
                    in_sync <= {in_sync[1:0], in_signal};
                end
            end
            wire in_sync2 = in_sync[2];
            wire in_sync1 = in_sync[1];
            logic src;
            wire [1:0] reg_in_ctrl_mode = reg_in_ctrl[j][1:0];
            always_comb begin
                case (reg_in_ctrl_mode)
                    2'b00: src = in_sync2;  // sync'd input
                    2'b01: src = ~in_sync2;  // invert sync'd input
                    2'b10: src = in_sync2 && ~in_sync1;  // Falling Edge
                    2'b11: src = ~in_sync2 && in_sync1;  // Rising Edge
                    default: src = 1'b0;
                endcase
            end
            assign timer_in_src[j] = src;
        end
    endgenerate


    generate
        for (j = 0; j < TIMER_NUM; j = j + 1) begin : gen_timers

            wire cmd_write = (adr_i[11:2] == (TIMER0_CMD + 10'(j * 'h10))) && (we_i && sel_i[0] && ack_o);

            wire sw_start = cmd_write && dat_i[0];
            wire sw_stop = cmd_write && dat_i[1];
            wire sw_reset = cmd_write && dat_i[2];

            // collect start sources
            wire start = sw_start
                || |{cmp_output & reg_timer_ctrl0[j][8+:TIMER_CMP]}
                || |{timer_in_src & reg_timer_ctrl1[j][8+:TIMER_INPUTS]};
            wire stop = sw_stop
                || |{cmp_output & reg_timer_ctrl0[j][16+:TIMER_CMP]} 
                || |{timer_in_src & reg_timer_ctrl1[j][16+:TIMER_INPUTS]};
            wire reset = sw_reset
                || |{cmp_output & reg_timer_ctrl0[j][24+:TIMER_CMP]} 
                || |{timer_in_src & reg_timer_ctrl1[j][24+:TIMER_INPUTS]};

            counter #(
                .WIDTH(TIMER_WIDTH)
            ) u_cnt (
                .clk_i(clk_i),
                .rst_n(reg_timer_ctrl0[j][0]),

                .start_i(start),
                .stop_i (stop),
                .reset_i(reset),

                .running_o(timer_running[j]),
                .timer_o  (timer_value[j])
            );
        end
    endgenerate

    generate
        for (j = 0; j < TIMER_CMP; j = j + 1) begin : gen_cmp
            logic [TIMER_WIDTH-1:0] cmp_timer_val;
            wire  [ 2:0] timer_ch_sel = reg_cmp_ctrl[j][10:8]; // 8 timers max
            always_comb begin
                cmp_timer_val = {TIMER_WIDTH{'0}};
                for (int i = 0; i < TIMER_NUM; i = i + 1) begin
                    if (timer_ch_sel == i) cmp_timer_val = timer_value[i];
                end
            end

            cmp #(
                .WIDTH(TIMER_WIDTH)
            ) u_cmp (
                .timer_i    (cmp_timer_val),
                .cmp_value_i(reg_cmp_value[j]),
                .cmp_mode_i (reg_cmp_ctrl[j][1:0]),

                .cmp_o(cmp_output[j])
            );
        end
    endgenerate

    wire wb_active = cyc_i && stb_i & !ack_o;

    // WB port
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            ack_o <= 1'b0;

            for (int i = 0; i < TIMER_NUM; i++) begin
                reg_timer_ctrl0[i] <= '0;
                reg_timer_ctrl1[i] <= '0;
            end
            for (int i = 0; i < TIMER_CMP; i++) begin
                reg_cmp_ctrl[i]  <= '0;
                reg_cmp_value[i] <= '0;
            end
            for (int i = 0; i < TIMER_OUTPUTS; i++) begin
                reg_out_ctrl[i] <= '0;
            end
            for (int i = 0; i < TIMER_INPUTS; i++) begin
                reg_in_ctrl[i] <= '0;
            end
        end else begin
            if (wb_active) begin
                ack_o <= 1'b1;

                if (we_i) begin
                    for (int i = 0; i < TIMER_NUM; i++) begin
                        if (adr_i[11:2] == (TIMER0_CTRL0 + 10'(i * 'h10))) begin
                            for (int b = 0; b < 4; b++) begin
                                if (sel_i[b]) reg_timer_ctrl0[i][b*8+:8] <= dat_i[b*8+:8];
                            end
                        end
                        if (adr_i[11:2] == (TIMER0_CTRL1 + 10'(i * 'h10))) begin
                            for (int b = 0; b < 4; b++) begin
                                if (sel_i[b]) reg_timer_ctrl1[i][b*8+:8] <= dat_i[b*8+:8];
                            end
                        end
                    end
                    for (int i = 0; i < TIMER_CMP; i++) begin
                        if (adr_i[11:2] == (CMP0_CTRL + 10'(i * 'h10))) begin
                            for (int b = 0; b < 4; b++) begin
                                if (sel_i[b]) reg_cmp_ctrl[i][b*8+:8] <= dat_i[b*8+:8];
                            end
                        end
                        if (adr_i[11:2] == (CMP0_VALUE + 10'(i * 'h10))) begin
                            for (int b = 0; b < 4; b++) begin
                                if (sel_i[b]) reg_cmp_value[i][b*8+:8] <= dat_i[b*8+:8];
                            end
                        end
                    end
                    for (int i = 0; i < TIMER_OUTPUTS; i++) begin
                        if (adr_i[11:2] == (OUT0_CTRL + 10'(i * 'h10))) begin
                            for (int b = 0; b < 4; b++) begin
                                if (sel_i[b]) reg_out_ctrl[i][b*8+:8] <= dat_i[b*8+:8];
                            end
                        end
                    end
                    for (int i = 0; i < TIMER_INPUTS; i++) begin
                        if (adr_i[11:2] == (IN0_CTRL + 10'(i * 'h10))) begin
                            for (int b = 0; b < 2; b++) begin
                                if (sel_i[b]) reg_in_ctrl[i][b*8+:8] <= dat_i[b*8+:8];
                            end
                        end
                    end
                end else begin
                    for (int i = 0; i < TIMER_CMP; i++) begin
                        if (adr_i[11:2] == (CMP0_HCF + 10'(i * 'h10))) begin
                            ack_o <= cmp_output[i];
                        end
                    end
                    for (int i = 0; i < TIMER_INPUTS; i++) begin
                        if (adr_i[11:2] == (IN0_HCF + 10'(i * 'h10))) begin
                            ack_o <= timer_in_src[i];
                        end
                    end
                end
            end else begin
                ack_o <= 1'b0;
            end
        end
    end

    // dat_o logic
    wire [9:0] reg_adr = adr_i[11:2];
    always_comb begin
        dat_o = 32'd0;
        if (reg_adr == STATUS) begin
            dat_o = {{(16 - TIMER_NUM) {1'b0}}, timer_running, {(16 - TIMER_CMP) {1'b0}}, cmp_output};
        end

        for (int i = 0; i < TIMER_NUM; i++) begin
            if (reg_adr == (TIMER0_CTRL0 + 10'(i * 'h10))) begin
                dat_o = reg_timer_ctrl0[i];
            end
            if (reg_adr == (TIMER0_CTRL1 + 10'(i * 'h10))) begin
                dat_o = reg_timer_ctrl1[i];
            end
            if (reg_adr == (TIMER0_VALUE + 10'(i * 'h10))) begin
                dat_o = {{(32 - TIMER_WIDTH){1'b0}},timer_value[i]};
            end
        end
        for (int i = 0; i < TIMER_CMP; i++) begin
            if (reg_adr == (CMP0_CTRL + 10'(i * 'h10))) begin
                dat_o = reg_cmp_ctrl[i];
            end
            if (reg_adr == (CMP0_VALUE + 10'(i * 'h10))) begin
                dat_o = reg_cmp_value[i];
            end
        end
        for (int i = 0; i < TIMER_OUTPUTS; i++) begin
            if (reg_adr == (OUT0_CTRL + 10'(i * 'h10))) begin
                dat_o = reg_out_ctrl[i];
            end
        end
        for (int i = 0; i < TIMER_INPUTS; i++) begin
            if (reg_adr == (IN0_CTRL + 10'(i * 'h10))) begin
                dat_o = {24'd0, reg_in_ctrl[i]};
            end
            if (reg_adr == (IN0_VALUE + 10'(i * 'h10))) begin
                dat_o = {31'd0, timer_in_src[i]};
            end
            if (reg_adr == (IN0_HCF + 10'(i * 'h10))) begin
                dat_o = {31'd0, timer_in_src[i]};
            end
        end
    end
endmodule


module counter #(
    parameter integer WIDTH = 32
) (
    input logic clk_i,
    input logic rst_n,

    input logic start_i,
    input logic stop_i,
    input logic reset_i,

    output logic running_o,
    output logic [WIDTH-1:0] timer_o
);

    logic [WIDTH-1:0] counter;
    logic running;

    assign timer_o   = counter;
    assign running_o = running;

    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            counter <= {WIDTH{'0}};
            running <= 1'b0;
        end else begin
            if (start_i) running <= 1'b1;
            else if (stop_i) running <= 1'b0;

            if (reset_i) counter <= {WIDTH{'0}};
            else if (running) counter <= counter + {{WIDTH{'0}}, 1'b1};
        end
    end
endmodule


module cmp #(
    parameter integer WIDTH = 32
) (
    input logic [WIDTH-1:0] timer_i,
    input logic [WIDTH-1:0] cmp_value_i,
    input logic [ 1:0] cmp_mode_i,

    output logic cmp_o
);
    always_comb begin
        case (cmp_mode_i)
            2'b00: cmp_o = timer_i == cmp_value_i;
            2'b01: cmp_o = timer_i != cmp_value_i;
            2'b10: cmp_o = timer_i <= cmp_value_i;
            2'b11: cmp_o = timer_i >= cmp_value_i;
            default: cmp_o = 1'b0;
        endcase
    end
endmodule
