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

    wire spi_cs;
    wire spi_sck;
    wire spi_copi;
    wire spi_cipo;


    logic [3:0] gpio_a_alt_in[32];
    logic [3:0] gpio_a_alt_out[32];
    logic [3:0] gpio_a_alt_dir[32];

    logic [1:0] gpio_a_alt[32];
    logic [31:0] gpio_a_in;
    logic [31:0] gpio_a_out;
    logic [31:0] gpio_a_dir;
    logic [31:0] gpio_a_schmit;
    logic [31:0] gpio_a_slew;
    logic [31:0] gpio_a_pu;
    logic [31:0] gpio_a_pd;

    localparam integer NUM_PROC_CORES = 28;
    localparam integer NUM_WB_RESPONDERS = 4;

    localparam integer GPIOA_IDX = 0;
    localparam integer QUEUE0_WR_IDX = 1;
    localparam integer QUEUE0_RD_IDX = 2;
    localparam integer UART0_IDX = 3;
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

    racquet u_racquet (
        .clk  (clk),
        .rst_n(rst_n),

        .cs  (spi_cs),
        .copi(spi_copi),
        .cipo(spi_cipo),
        .sck (spi_sck),

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



    // Set the bidir as output
    // assign bidir_oe = '1;
    assign bidir_ie = ~bidir_oe;
    assign bidir_cs[53:32] = '0;
    assign bidir_sl[53:32] = '0;
    assign bidir_pu[53:32] = '0;
    assign bidir_pd[53:32] = '0;

    assign bidir_out[32] = spi_cs;
    assign bidir_out[33] = spi_sck;
    assign bidir_out[34] = spi_copi;
    assign bidir_out[35] = 1'b0;
    assign spi_cipo = bidir_in[35];

    assign bidir_oe[34:32] = '1;
    assign bidir_oe[35] = '0;
    assign bidir_oe[53:36] = '1;
    assign bidir_out[53:36] = '0;

    logic _unused;
    assign _unused = &bidir_in[53:32];

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html

    // GPIO A connections to padframe
    assign bidir_out[31:0] = gpio_a_out;
    assign bidir_oe[31:0] = gpio_a_dir;
    assign bidir_pd[31:0] = gpio_a_pd;
    assign bidir_pu[31:0] = gpio_a_pu;
    assign bidir_sl[31:0] = gpio_a_slew;
    assign bidir_cs[31:0] = gpio_a_schmit;
    assign gpio_a_in = bidir_in[31:0];

    // Hook up peripherals
    assign gpio_a_alt_out[0] = {1'b0, 1'b0, uart0_tx, 1'b0};
    assign gpio_a_alt_dir[0] = {1'b0, 1'b0, 1'b1, 1'b0};

    assign gpio_a_alt_out[1] = {1'b0, uart0_tx, 1'b0, 1'b0};
    assign gpio_a_alt_dir[1] = {1'b0, 1'b1, 1'b0, 1'b0};

    assign uart0_rx = (gpio_a_alt_in[0][2] | gpio_a_alt_in[1][1]);

    genvar j;
    generate
        for (j = 2; j < 32; j = j + 1) begin : gen_defaults
            assign gpio_a_alt_out[j] = '0;
            assign gpio_a_alt_dir[j] = '0;
        end
    endgenerate






endmodule

`default_nettype wire
