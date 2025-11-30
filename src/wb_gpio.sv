module wb_gpio #(
    parameter GPIO_NUM = 8
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

    // ALT connections
    output logic [3:0] alt_in_o [GPIO_NUM],
    input  logic [3:0] alt_out_i[GPIO_NUM],
    input  logic [3:0] alt_dir_i[GPIO_NUM],

    // GPIO control
    output logic [GPIO_NUM-1:0] io_out_o,
    output logic [GPIO_NUM-1:0] io_dir_o,
    input  logic [GPIO_NUM-1:0] io_in_i,
    output logic [GPIO_NUM-1:0] io_pu_o,
    output logic [GPIO_NUM-1:0] io_pd_o,
    output logic [GPIO_NUM-1:0] io_slew_o,
    output logic [GPIO_NUM-1:0] io_schmit_o,

    output logic [1:0] io_alt_o[GPIO_NUM]
);

    // Register address map, word addresses
    localparam logic [9:0] OUT_DAT = 10'h0;
    localparam logic [9:0] OUT_SET = 10'h1;
    localparam logic [9:0] OUT_CLR = 10'h2;
    localparam logic [9:0] OUT_TOG = 10'h3;

    localparam logic [9:0] DIR_DAT = 10'h4;
    localparam logic [9:0] DIR_SET = 10'h5;
    localparam logic [9:0] DIR_CLR = 10'h6;
    localparam logic [9:0] DIR_TOG = 10'h7;

    localparam logic [9:0] PU_DAT = 10'h8;
    localparam logic [9:0] PU_SET = 10'h9;
    localparam logic [9:0] PU_CLR = 10'ha;
    localparam logic [9:0] PU_TOG = 10'hb;

    localparam logic [9:0] PD_DAT = 10'hc;
    localparam logic [9:0] PD_SET = 10'hd;
    localparam logic [9:0] PD_CLR = 10'he;
    localparam logic [9:0] PD_TOG = 10'hf;

    localparam logic [9:0] IN_DAT = 10'h10;

    localparam logic [9:0] SLEW = 10'h20;
    localparam logic [9:0] SCHMIT = 10'h21;

    localparam logic [9:0] ALT0 = 10'h80;

    // Registers
    logic [GPIO_NUM-1:0] reg_out;
    logic [GPIO_NUM-1:0] reg_dir;
    logic [GPIO_NUM-1:0] reg_slew;
    logic [GPIO_NUM-1:0] reg_schmit;
    logic [GPIO_NUM-1:0] reg_pu;
    logic [GPIO_NUM-1:0] reg_pd;

    logic [GPIO_NUM-1:0] in_sync;
    logic [GPIO_NUM-1:0] reg_in;  // 2nd register for inputs

    logic [1:0] reg_alt[GPIO_NUM];

    // io register assignments
    // assign io_out_o = reg_out; // handled by ALT IO logic below
    // assign io_dir_o = reg_dir;
    assign io_pu_o = reg_pu;
    assign io_pd_o = reg_pd;
    assign io_slew_o = reg_slew;
    assign io_schmit_o = reg_schmit;
    assign io_alt_o = reg_alt;

    // ALT IO assignments
    // iverilog doesn't like bit_selects within alway_comb/always(*) blocks..
    // break up arrays into single variables, do selections, then combine
    genvar g, k;
    generate
        for (g = 0; g < GPIO_NUM; g = g + 1) begin : gen_alt_io
            logic _out, _dir, _reg_out, _reg_in, _reg_dir;
            logic _alt1_out, _alt1_dir, _alt2_out, _alt2_dir, _alt3_out, _alt3_dir, _alt1_in, _alt2_in, _alt3_in;
            assign _reg_in = reg_in[g];
            assign {_reg_out, _reg_dir} = {reg_out[g], reg_dir[g]};
            assign {_alt1_out, _alt1_dir} = {alt_out_i[g][1], alt_dir_i[g][1]};
            assign {_alt2_out, _alt2_dir} = {alt_out_i[g][2], alt_dir_i[g][2]};
            assign {_alt3_out, _alt3_dir} = {alt_out_i[g][3], alt_dir_i[g][3]};

            always_comb begin
                // default state
                {_alt3_in, _alt2_in, _alt1_in} = 3'b000;

                // alt == 0, register controlled
                case (reg_alt[g])
                    0: {_out, _dir} = {_reg_out, _reg_dir};
                    // alt > 0, peripheral controlled out/dir
                    1: {_out, _dir, _alt1_in} = {_alt1_out, _alt1_dir, _reg_in};
                    2: {_out, _dir, _alt2_in} = {_alt2_out, _alt2_dir, _reg_in};
                    3: {_out, _dir, _alt3_in} = {_alt3_out, _alt3_dir, _reg_in};
                    default: begin end
                endcase
            end

            assign io_out_o[g] = _out;
            assign io_dir_o[g] = _dir;
            assign alt_in_o[g] = {_alt3_in, _alt2_in, _alt1_in, 1'b0};
        end
    endgenerate

    wire wb_active = cyc_i && stb_i & !ack_o;

    // WB port
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            dat_o <= 32'd0;
            ack_o <= 1'b0;
        end else begin
            if (wb_active) begin
                ack_o <= 1'b1;  // Accept reads/writes on entire register space.

                // dat_o logic
                if (!we_i) begin
                    casex (adr_i[11:2])
                        OUT_DAT: dat_o <= reg_out;
                        OUT_SET: dat_o <= reg_out;
                        OUT_CLR: dat_o <= reg_out;
                        OUT_TOG: dat_o <= reg_out;

                        DIR_DAT: dat_o <= reg_dir;
                        DIR_SET: dat_o <= reg_dir;
                        DIR_CLR: dat_o <= reg_dir;
                        DIR_TOG: dat_o <= reg_dir;

                        PU_DAT: dat_o <= reg_pu;
                        PU_SET: dat_o <= reg_pu;
                        PU_CLR: dat_o <= reg_pu;
                        PU_TOG: dat_o <= reg_pu;

                        PD_DAT: dat_o <= reg_pd;
                        PD_SET: dat_o <= reg_pd;
                        PD_CLR: dat_o <= reg_pd;
                        PD_TOG: dat_o <= reg_pd;

                        IN_DAT: dat_o <= reg_in;

                        SLEW:   dat_o <= reg_slew;
                        SCHMIT: dat_o <= reg_schmit;

                        10'b001xxxxxxx: dat_o <= {30'd0, reg_alt[adr_i[7:2]]};
                        default: begin
                        end
                    endcase
                end
            end else begin
                ack_o <= 1'b0;
            end
        end
    end

    // reg_in logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_in  <= 32'd0;
            in_sync <= 32'd0;
        end else begin
            in_sync <= io_in_i;
            reg_in  <= in_sync;
        end
    end

    // reg_out logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_out <= 32'd0;
        end else begin
            for (int b = 0; b < 4; b++) begin
                if (wb_active && we_i && sel_i[b]) begin
                    case (adr_i[11:2])
                        OUT_DAT: reg_out[b*8+:8] <= dat_i[b*8+:8];
                        OUT_SET: reg_out[b*8+:8] <= reg_out[b*8+:8] | dat_i[b*8+:8];
                        OUT_CLR: reg_out[b*8+:8] <= reg_out[b*8+:8] & ~dat_i[b*8+:8];
                        OUT_TOG: reg_out[b*8+:8] <= reg_out[b*8+:8] ^ dat_i[b*8+:8];
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    // reg_dir logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_dir <= 32'd0;
        end else begin
            for (int b = 0; b < 4; b++) begin
                if (wb_active && we_i && sel_i[b]) begin
                    case (adr_i[11:2])
                        DIR_DAT: reg_dir[b*8+:8] <= dat_i[b*8+:8];
                        DIR_SET: reg_dir[b*8+:8] <= reg_dir[b*8+:8] | dat_i[b*8+:8];
                        DIR_CLR: reg_dir[b*8+:8] <= reg_dir[b*8+:8] & ~dat_i[b*8+:8];
                        DIR_TOG: reg_dir[b*8+:8] <= reg_dir[b*8+:8] ^ dat_i[b*8+:8];
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    // reg_pu logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_pu <= 32'd0;
        end else begin
            for (int b = 0; b < 4; b++) begin
                if (wb_active && we_i && sel_i[b]) begin
                    case (adr_i[11:2])
                        PU_DAT: reg_pu[b*8+:8] <= dat_i[b*8+:8];
                        PU_SET: reg_pu[b*8+:8] <= reg_pu[b*8+:8] | dat_i[b*8+:8];
                        PU_CLR: reg_pu[b*8+:8] <= reg_pu[b*8+:8] & ~dat_i[b*8+:8];
                        PU_TOG: reg_pu[b*8+:8] <= reg_pu[b*8+:8] ^ dat_i[b*8+:8];
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    // reg_pd logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_pd <= 32'd0;
        end else begin
            for (int b = 0; b < 4; b++) begin
                if (wb_active && we_i && sel_i[b]) begin
                    case (adr_i[11:2])
                        PD_DAT: reg_pd[b*8+:8] <= dat_i[b*8+:8];
                        PD_SET: reg_pd[b*8+:8] <= reg_pd[b*8+:8] | dat_i[b*8+:8];
                        PD_CLR: reg_pd[b*8+:8] <= reg_pd[b*8+:8] & ~dat_i[b*8+:8];
                        PD_TOG: reg_pd[b*8+:8] <= reg_pd[b*8+:8] ^ dat_i[b*8+:8];
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    // reg_slew logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_slew <= '1;
        end else begin
            for (int b = 0; b < 4; b++) begin
                if (wb_active && we_i && sel_i[b]) begin
                    case (adr_i[11:2])
                        SLEW: reg_slew[b*8+:8] <= dat_i[b*8+:8];
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    // reg_schmit logic
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            reg_schmit <= '1;
        end else begin
            for (int b = 0; b < 4; b++) begin
                if (wb_active && we_i && sel_i[b]) begin
                    case (adr_i[11:2])
                        SCHMIT: reg_schmit[b*8+:8] <= dat_i[b*8+:8];
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    // reg_alt logic
    genvar j;
    generate
        for (j = 0; j < GPIO_NUM; j = j + 1) begin : gen_alt_reg
            logic [1:0] reg_;
            assign reg_ = reg_alt[j];
            always_ff @(posedge clk_i or negedge rst_n) begin
                if (!rst_n) begin
                    reg_alt[j] <= 2'd0;
                end else begin
                    if (wb_active && we_i && sel_i[0]) begin
                        if (adr_i[11:2] == 10'(ALT0 + j)) begin
                            reg_alt[j][1:0] <= dat_i[1:0];
                        end
                    end
                end
            end
        end
    endgenerate


endmodule

