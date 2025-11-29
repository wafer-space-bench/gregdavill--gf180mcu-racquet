// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
) (
`ifdef USE_POWER_PINS
    inout wire VDD,
    inout wire VSS,
`endif

    input wire clk,   // clock
    input wire rst_n, // reset (active low)

    input  wire [NUM_INPUT_PADS-1:0] input_in,  // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,  // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,  // Pull-down

    input wire [NUM_BIDIR_PADS-1:0] bidir_in,  // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,  // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,  // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,  // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,  // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,  // Pull-down

    inout  wire [NUM_ANALOG_PADS-1:0] analog  // Analog
);

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html

    // Disable pull-up and pull-down for input
    assign input_pu = '0;
    assign input_pd = '0;

    // Set the bidir as output
    // assign bidir_oe = '1;
    assign bidir_cs = '0;
    assign bidir_sl = '0;
    assign bidir_ie = ~bidir_oe;
    assign bidir_pu = '0;
    assign bidir_pd = '0;

    logic _unused;
    assign _unused = &bidir_in;


    parameter memsize = 512;
    localparam aw = $clog2(memsize);

    wire spi_cs;
    wire spi_sck;
    wire spi_copi;
    wire spi_cipo;

    wire o_gpio;


    assign bidir_out[0] = o_gpio;

    assign bidir_out[1] = spi_cs;
    assign bidir_out[2] = spi_sck;
    assign bidir_out[3] = spi_copi;


    assign spi_cipo = bidir_in[4];

    assign bidir_oe[NUM_BIDIR_PADS-1:5] = '1;
    assign bidir_oe[3:0] = '1;
    assign bidir_oe[4] = '0;
    assign bidir_out[NUM_BIDIR_PADS-1:4] = '0;

    localparam integer NUM_PROC_CORES = 4;
    localparam integer NUM_WB_RESPONDERS = 3;
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

    assign wb_resp_err[0] = '0;

    // Peripherals
    subservient_gpio u_gpio (
        .i_wb_clk(clk),
        .i_wb_rst(~rst_n),
        .i_wb_dat(wb_resp_wdt[0][0]),
        .i_wb_we (wb_resp_we[0]),
        .i_wb_stb(wb_resp_stb[0]),
        .o_wb_rdt(wb_resp_rdt[0][0]),
        .o_wb_ack(wb_resp_ack[0]),
        .o_gpio  (o_gpio)
    );

    assign wb_resp_rdt[0][31:1] = '0;

    wb_queue u_queue0 (
        .clk_i(clk),
        .rst_n(rst_n),

        .wr_cyc_i(wb_resp_cyc[1]),
        .wr_stb_i(wb_resp_stb[1]),
        .wr_we_i (wb_resp_we[1]),
        .wr_sel_i(wb_resp_sel[1]),
        .wr_adr_i(wb_resp_adr[1]),
        .wr_dat_i(wb_resp_wdt[1]),
        .wr_dat_o(wb_resp_rdt[1]),
        .wr_ack_o(wb_resp_ack[1]),

        .rd_cyc_i(wb_resp_cyc[2]),
        .rd_stb_i(wb_resp_stb[2]),
        .rd_we_i (wb_resp_we[2]),
        .rd_sel_i(wb_resp_sel[2]),
        .rd_adr_i(wb_resp_adr[2]),
        .rd_dat_i(wb_resp_wdt[2]),
        .rd_dat_o(wb_resp_rdt[2]),
        .rd_ack_o(wb_resp_ack[2])
    );
    assign wb_resp_err[1] = '0;
    assign wb_resp_err[2] = '0;


endmodule

`default_nettype wire
