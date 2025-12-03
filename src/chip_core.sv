// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module chip_core #(
    parameter NUM_BIDIR_PADS
) (
`ifdef USE_POWER_PINS
    inout wire VDD,
    inout wire VSS,
`endif

    input logic clk,   // clock
    input logic rst_n, // reset (active low)

    input  logic [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
    output logic [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output logic [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
    output logic [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    output logic [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
    output logic [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
    output logic [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
    output logic [NUM_BIDIR_PADS-1:0] bidir_pd    // Pull-down
);

    parameter memsize = 512;
    localparam aw = $clog2(memsize);

    logic [1:0] gpio_a_alt_in[32];
    logic [1:0] gpio_a_alt_out[32];
    logic [1:0] gpio_a_alt_dir[32];

    logic [0:0] gpio_a_alt[32];
    logic [31:0] gpio_a_in;
    logic [31:0] gpio_a_out;
    logic [31:0] gpio_a_dir;
    logic [31:0] gpio_a_schmit;
    logic [31:0] gpio_a_slew;
    logic [31:0] gpio_a_pu;
    logic [31:0] gpio_a_pd;

    localparam integer GPIOB_NUM = 22;
    logic [1:0] gpio_b_alt_in[GPIOB_NUM];
    logic [1:0] gpio_b_alt_out[GPIOB_NUM];
    logic [1:0] gpio_b_alt_dir[GPIOB_NUM];

    logic [0:0] gpio_b_alt[GPIOB_NUM];
    logic [GPIOB_NUM-1:0] gpio_b_in;
    logic [GPIOB_NUM-1:0] gpio_b_out;
    logic [GPIOB_NUM-1:0] gpio_b_dir;
    logic [GPIOB_NUM-1:0] gpio_b_schmit;
    logic [GPIOB_NUM-1:0] gpio_b_slew;
    logic [GPIOB_NUM-1:0] gpio_b_pu;
    logic [GPIOB_NUM-1:0] gpio_b_pd;

    localparam integer NUM_PROC_CORES = 23;
    localparam integer NUM_WB_RESPONDERS = 6;

    localparam integer GPIOA_IDX = 0;
    localparam integer GPIOB_IDX = 1;
    localparam integer QUEUE0_WR_IDX = 2;
    localparam integer QUEUE0_RD_IDX = 3;
    localparam integer UART0_IDX = 4;
    localparam integer TIMER0_IDX = 5;
    genvar i;

    // Controller WB busses
    logic [31:0] wb_adr         [    NUM_PROC_CORES];
    logic [31:0] wb_wdt         [    NUM_PROC_CORES];
    logic [ 3:0] wb_sel         [    NUM_PROC_CORES];
    logic        wb_we          [    NUM_PROC_CORES];
    logic        wb_stb         [    NUM_PROC_CORES];
    logic [31:0] wb_rdt         [    NUM_PROC_CORES];
    logic        wb_ack         [    NUM_PROC_CORES];

    // Responder WB busses
    logic [11:0] wb_resp_adr    [ NUM_WB_RESPONDERS];
    logic [31:0] wb_resp_wdt    [ NUM_WB_RESPONDERS];
    logic [ 3:0] wb_resp_sel    [ NUM_WB_RESPONDERS];
    logic        wb_resp_we     [ NUM_WB_RESPONDERS];
    logic        wb_resp_cyc    [ NUM_WB_RESPONDERS];
    logic        wb_resp_stb    [ NUM_WB_RESPONDERS];
    logic [31:0] wb_resp_rdt    [ NUM_WB_RESPONDERS];
    logic        wb_resp_ack    [ NUM_WB_RESPONDERS];
    logic        wb_resp_err    [ NUM_WB_RESPONDERS];

    // Proc loader signals
    logic        loader_enabled;
    logic [ 7:0] loader_wdata   [NUM_PROC_CORES + 1];
    logic        loader_valid   [NUM_PROC_CORES + 1];
    logic        loader_ready   [NUM_PROC_CORES + 1];

    generate
        for (i = 0; i < NUM_PROC_CORES; i = i + 1) begin : gen_proc_wrapper
            proc_wrapper u_proc_wrapper (
`ifdef USE_POWER_PINS
                .VDD(VDD),
                .VSS(VSS),
`endif

                .i_clk(clk),   // clock
                .i_rst(rst_n), // reset (active low)

                // WB bus
                .wb_adr_o(wb_adr[i]),
                .wb_dat_o(wb_wdt[i]),
                .wb_sel_o(wb_sel[i]),
                .wb_we_o (wb_we[i]),
                .wb_stb_o(wb_stb[i]),
                .wb_rdt_i(wb_rdt[i]),
                .wb_ack_i(wb_ack[i]),

                .i_loader_en(loader_enabled),

                // Loader stream interface in
                .i_loader_i_wdata(loader_wdata[i]),
                .i_loader_i_valid(loader_valid[i]),
                .o_loader_i_ready(loader_ready[i]),

                // Loader stream interface out, to next core
                .o_loader_o_wdata(loader_wdata[i+1]),
                .o_loader_o_valid(loader_valid[i+1]),
                .i_loader_o_ready(loader_ready[i+1])
            );
        end
    endgenerate

    // Last core ready signal tied high
    assign loader_ready[NUM_PROC_CORES] = 1'b1;

    wire cfg_spi_cs;
    wire cfg_spi_sck;
    wire cfg_spi_copi;
    wire cfg_spi_cipo;

    racquet u_racquet (
        .clk  (clk),
        .rst_n(rst_n),

        .cs  (cfg_spi_cs),
        .copi(cfg_spi_copi),
        .cipo(cfg_spi_cipo),
        .sck (cfg_spi_sck),

        .loader_enabled(loader_enabled),

        .o_loader_payload(loader_wdata[0]),
        .o_loader_valid  (loader_valid[0]),
        .i_loader_ready  (loader_ready[0])
    );


    // Main peripheral xbar
    wb_xbar #(
        .NUM_MASTERS(NUM_PROC_CORES),
        .NUM_SLAVES (NUM_WB_RESPONDERS)
    ) u_wb_xbar (
        .clk  (clk),
        .rst_n(rst_n),

        .m_adr_i(wb_adr),
        .m_dat_i(wb_wdt),
        .m_sel_i(wb_sel),
        .m_we_i(wb_we),
        .m_stb_i(wb_stb),
        .m_cyc_i(wb_stb),  /* ignore fancier wb cycles. */
        .m_dat_o(wb_rdt),
        .m_ack_o(wb_ack),
        .m_err_o(  /* open */),

        .s_adr_o(wb_resp_adr),
        .s_dat_o(wb_resp_wdt),
        .s_sel_o(wb_resp_sel),
        .s_we_o (wb_resp_we),
        .s_stb_o(wb_resp_stb),
        .s_cyc_o(wb_resp_cyc),
        .s_dat_i(wb_resp_rdt),
        .s_ack_i(wb_resp_ack),
        .s_err_i(wb_resp_err)
    );

    // Peripherals
    wb_gpio #(
        .GPIO_NUM(32)
    ) u_gpioa (
        .clk_i(clk),
        .rst_n(rst_n),

        .adr_i(wb_resp_adr[GPIOA_IDX]),
        .dat_i(wb_resp_wdt[GPIOA_IDX]),
        .dat_o(wb_resp_rdt[GPIOA_IDX]),
        .sel_i(wb_resp_sel[GPIOA_IDX]),
        .we_i (wb_resp_we[GPIOA_IDX]),
        .stb_i(wb_resp_stb[GPIOA_IDX]),
        .cyc_i(wb_resp_cyc[GPIOA_IDX]),
        .ack_o(wb_resp_ack[GPIOA_IDX]),

        // ALT peripheral connections
        .alt_in_o (gpio_a_alt_in),
        .alt_out_i (gpio_a_alt_out),
        .alt_dir_i (gpio_a_alt_dir),

        // GPIO control
        .io_out_o (gpio_a_out),
        .io_dir_o (gpio_a_dir),
        .io_in_i  (gpio_a_in),
        .io_pu_o  (gpio_a_pu),
        .io_pd_o  (gpio_a_pd),
        .io_slew_o(gpio_a_slew),
        .io_schmit_o(gpio_a_schmit),

        .io_alt_o(gpio_a_alt)
    );
    assign wb_resp_err[GPIOA_IDX] = '0;  // not used by peripheral

    localparam logic [GPIOB_NUM-1:0] GPIOB_INIT_ALT = {{(GPIOB_NUM-4){1'b0}}, {4{1'b1}}};
    // ideally this is cleaner as an unpacked array. But iverilog doesn't support unpacked array parameters:
    // error: sorry: unpacked array parameters are not supported yet
    // Create a packed array to select the the cfg_spi alt mode on reset
    wb_gpio #(
        .GPIO_NUM(GPIOB_NUM),
        .INIT_ALT(GPIOB_INIT_ALT)
    ) u_gpiob (
        .clk_i(clk),
        .rst_n(rst_n),

        .adr_i(wb_resp_adr[GPIOB_IDX]),
        .dat_i(wb_resp_wdt[GPIOB_IDX]),
        .dat_o(wb_resp_rdt[GPIOB_IDX]),
        .sel_i(wb_resp_sel[GPIOB_IDX]),
        .we_i (wb_resp_we[GPIOB_IDX]),
        .stb_i(wb_resp_stb[GPIOB_IDX]),
        .cyc_i(wb_resp_cyc[GPIOB_IDX]),
        .ack_o(wb_resp_ack[GPIOB_IDX]),

        // ALT peripheral connections
        .alt_in_o (gpio_b_alt_in),
        .alt_out_i (gpio_b_alt_out),
        .alt_dir_i (gpio_b_alt_dir),

        // GPIO control
        .io_out_o (gpio_b_out),
        .io_dir_o (gpio_b_dir),
        .io_in_i  (gpio_b_in),
        .io_pu_o  (gpio_b_pu),
        .io_pd_o  (gpio_b_pd),
        .io_slew_o(gpio_b_slew),
        .io_schmit_o(gpio_b_schmit),

        .io_alt_o(gpio_b_alt)
    );
    assign wb_resp_err[GPIOB_IDX] = '0;  // not used by peripheral

    wb_queue u_queue0 (
        .clk_i(clk),
        .rst_n(rst_n),

        .wr_cyc_i(wb_resp_cyc[QUEUE0_WR_IDX]),
        .wr_stb_i(wb_resp_stb[QUEUE0_WR_IDX]),
        .wr_we_i (wb_resp_we[QUEUE0_WR_IDX]),
        .wr_sel_i(wb_resp_sel[QUEUE0_WR_IDX]),
        .wr_adr_i(wb_resp_adr[QUEUE0_WR_IDX]),
        .wr_dat_i(wb_resp_wdt[QUEUE0_WR_IDX]),
        .wr_dat_o(wb_resp_rdt[QUEUE0_WR_IDX]),
        .wr_ack_o(wb_resp_ack[QUEUE0_WR_IDX]),

        .rd_cyc_i(wb_resp_cyc[QUEUE0_RD_IDX]),
        .rd_stb_i(wb_resp_stb[QUEUE0_RD_IDX]),
        .rd_we_i (wb_resp_we[QUEUE0_RD_IDX]),
        .rd_sel_i(wb_resp_sel[QUEUE0_RD_IDX]),
        .rd_adr_i(wb_resp_adr[QUEUE0_RD_IDX]),
        .rd_dat_i(wb_resp_wdt[QUEUE0_RD_IDX]),
        .rd_dat_o(wb_resp_rdt[QUEUE0_RD_IDX]),
        .rd_ack_o(wb_resp_ack[QUEUE0_RD_IDX])
    );
    assign wb_resp_err[QUEUE0_WR_IDX] = '0;
    assign wb_resp_err[QUEUE0_RD_IDX] = '0;


    logic uart0_tx, uart0_rx;
    wb_uart u_uart0 (
        .clk_i(clk),
        .rst_n(rst_n),

        .adr_i(wb_resp_adr[UART0_IDX]),
        .dat_i(wb_resp_wdt[UART0_IDX]),
        .dat_o(wb_resp_rdt[UART0_IDX]),
        .sel_i(wb_resp_sel[UART0_IDX]),
        .we_i (wb_resp_we[UART0_IDX]),
        .stb_i(wb_resp_stb[UART0_IDX]),
        .cyc_i(wb_resp_cyc[UART0_IDX]),
        .ack_o(wb_resp_ack[UART0_IDX]),

        // UART pins
        .tx_o(uart0_tx),
        .rx_i(uart0_rx)
    );
    assign wb_resp_err[UART0_IDX] = '0;

    logic [7:0] timer0_out;
    logic [7:0] timer0_in;
    wb_timer #(
        .TIMER_NUM(4),
        .TIMER_CMP(4),
        .TIMER_OUTPUTS(8),
        .TIMER_INPUTS(8),
        .TIMER_WIDTH(24)
    ) u_timer0 (
        .clk_i(clk),
        .rst_n(rst_n),

        .adr_i(wb_resp_adr[TIMER0_IDX]),
        .dat_i(wb_resp_wdt[TIMER0_IDX]),
        .dat_o(wb_resp_rdt[TIMER0_IDX]),
        .sel_i(wb_resp_sel[TIMER0_IDX]),
        .we_i (wb_resp_we[TIMER0_IDX]),
        .stb_i(wb_resp_stb[TIMER0_IDX]),
        .cyc_i(wb_resp_cyc[TIMER0_IDX]),
        .ack_o(wb_resp_ack[TIMER0_IDX]),

        .timer_out(timer0_out),
        .timer_in(timer0_in)
    );
    assign wb_resp_err[TIMER0_IDX] = '0;  // not used by peripheral

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html

    // GPIO A connections to padframe
    assign bidir_out[31:0] = gpio_a_out;
    assign bidir_oe[31:0] = gpio_a_dir;
    assign bidir_ie[31:0] = ~gpio_a_dir;
    assign bidir_pd[31:0] = gpio_a_pd;
    assign bidir_pu[31:0] = gpio_a_pu;
    assign bidir_sl[31:0] = gpio_a_slew;
    assign bidir_cs[31:0] = gpio_a_schmit;
    assign gpio_a_in = bidir_in[31:0];

    // GPIO B connections to padframe
    assign bidir_out[53:32] = gpio_b_out;
    assign bidir_oe[53:32] = gpio_b_dir;
    assign bidir_ie[53:32] = ~gpio_b_dir;
    assign bidir_pd[53:32] = gpio_b_pd;
    assign bidir_pu[53:32] = gpio_b_pu;
    assign bidir_sl[53:32] = gpio_b_slew;
    assign bidir_cs[53:32] = gpio_b_schmit;
    assign gpio_b_in = bidir_in[53:32];

    // Hook up peripherals
    assign gpio_a_alt_out[0] = {timer0_out[0], 1'b0};
    assign gpio_a_alt_dir[0] = {1'b1, 1'b0};

    assign gpio_a_alt_out[1] = {timer0_out[1], 1'b0};
    assign gpio_a_alt_dir[1] = {1'b1, 1'b1};

    assign gpio_a_alt_out[2] = {timer0_out[2], 1'b0};
    assign gpio_a_alt_dir[2] = {1'b1, 1'b0};
    
    assign gpio_a_alt_out[3] = {timer0_out[3], 1'b0};
    assign gpio_a_alt_dir[3] = {1'b1, 1'b0};
    
    assign gpio_a_alt_out[4] = {timer0_out[4], 1'b0};
    assign gpio_a_alt_dir[4] = {1'b1, 1'b0};

    assign gpio_a_alt_out[5] = {timer0_out[5], 1'b0};
    assign gpio_a_alt_dir[5] = {1'b1, 1'b0};
    
    assign gpio_a_alt_out[6] = {timer0_out[6], 1'b0};
    assign gpio_a_alt_dir[6] = {1'b1, 1'b0};
    
    assign gpio_a_alt_out[7] = {timer0_out[7], 1'b0};
    assign gpio_a_alt_dir[7] = {1'b1, 1'b0};

    assign gpio_a_alt_out[8] = {timer0_out[0], 1'b0};
    assign gpio_a_alt_dir[8] = {1'b1, 1'b0};

    assign gpio_a_alt_out[9] = {timer0_out[1], 1'b0};
    assign gpio_a_alt_dir[9] = {1'b1, 1'b0};

    assign gpio_a_alt_out[10] = {timer0_out[2], 1'b0};
    assign gpio_a_alt_dir[10] = {1'b1, 1'b0};

    assign gpio_a_alt_out[11] = {timer0_out[3], 1'b0};
    assign gpio_a_alt_dir[11] = {1'b1, 1'b0};

    assign gpio_a_alt_out[12] = {timer0_out[4], 1'b0};
    assign gpio_a_alt_dir[12] = {1'b1, 1'b0};

    assign gpio_a_alt_out[13] = {timer0_out[5], 1'b0};
    assign gpio_a_alt_dir[13] = {1'b1, 1'b0};

    assign gpio_a_alt_out[14] = {timer0_out[6], 1'b0};
    assign gpio_a_alt_dir[14] = {1'b1, 1'b0};
    
    assign gpio_a_alt_out[15] = {timer0_out[7], 1'b0};
    assign gpio_a_alt_dir[15] = {1'b1, 1'b0};

    assign gpio_a_alt_out[16] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[16] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[17] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[17] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[18] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[18] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[19] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[19] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[20] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[20] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[21] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[21] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[22] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[22] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[23] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[23] = {1'b0, 1'b0};

    assign gpio_a_alt_out[24] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[24] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[25] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[25] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[26] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[26] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[27] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[27] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[28] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[28] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[29] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[29] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[30] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[30] = {1'b0, 1'b0};
    
    assign gpio_a_alt_out[31] = {1'b0, 1'b0};
    assign gpio_a_alt_dir[31] = {1'b0, 1'b0};


    assign timer0_in[0] = gpio_a_alt_in[16][1] |gpio_a_alt_in[24][1];
    assign timer0_in[1] = gpio_a_alt_in[17][1] |gpio_a_alt_in[25][1];
    assign timer0_in[2] = gpio_a_alt_in[18][1] |gpio_a_alt_in[26][1];
    assign timer0_in[3] = gpio_a_alt_in[19][1] |gpio_a_alt_in[27][1];
    assign timer0_in[4] = gpio_a_alt_in[20][1] |gpio_a_alt_in[28][1];
    assign timer0_in[5] = gpio_a_alt_in[21][1] |gpio_a_alt_in[29][1];
    assign timer0_in[6] = gpio_a_alt_in[22][1] |gpio_a_alt_in[30][1];
    assign timer0_in[7] = gpio_a_alt_in[23][1] |gpio_a_alt_in[31][1];

    genvar j;

    assign gpio_b_alt_out[0] = {cfg_spi_cs, 1'b0};
    assign gpio_b_alt_dir[0] = {1'b1, 1'b0};

    assign gpio_b_alt_out[1] = {cfg_spi_sck, 1'b0};
    assign gpio_b_alt_dir[1] = {1'b1, 1'b0};

    assign gpio_b_alt_out[2] = {cfg_spi_copi, 1'b0};
    assign gpio_b_alt_dir[2] = {1'b1, 1'b0};

    assign gpio_b_alt_out[3] = {1'b0, 1'b0};
    assign gpio_b_alt_dir[3] = {1'b0, 1'b0};
    assign cfg_spi_cipo = gpio_b_alt_in[3][1];

    assign gpio_b_alt_out[4] = {uart0_tx, 1'b0};
    assign gpio_b_alt_dir[4] = {1'b1, 1'b0};

    assign gpio_b_alt_out[5] = {1'b0, 1'b0};
    assign gpio_b_alt_dir[5] = {1'b0, 1'b0};
    assign uart0_rx = (gpio_a_alt_in[5][1]);

    generate
        for (j = 6; j < GPIOB_NUM; j = j + 1) begin : gen_gpiob_defaults
            assign gpio_b_alt_out[j] = '0;
            assign gpio_b_alt_dir[j] = '0;
        end
    endgenerate

endmodule

`default_nettype wire
