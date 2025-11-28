// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout wire VDD,
    inout wire VSS,
    `endif
    
    input  logic clk,       // clock
    input  logic rst_n,     // reset (active low)
    
    input  wire [NUM_INPUT_PADS-1:0] input_in,   // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,   // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,   // Pull-down

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,   // Pull-down

    inout  wire [NUM_ANALOG_PADS-1:0] analog  // Analog
);

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html
    
    // Disable pull-up and pull-down for input
    assign input_pu = '0;
    assign input_pd = '0;

    // Set the bidir as output
    assign bidir_oe = '1;
    assign bidir_cs = '0;
    assign bidir_sl = '0;
    assign bidir_ie = ~bidir_oe;
    assign bidir_pu = '0;
    assign bidir_pd = '0;
    
    logic _unused;
    assign _unused = &bidir_in;


   parameter memsize = 512;
   localparam aw    = $clog2(memsize);

   wire [aw-1:0] sram_waddr;
   wire [7:0] 	 sram_wdata;
   wire 	 sram_wen;
   wire [aw-1:0] sram_raddr;
   wire [7:0] 	 sram_rdata;
   wire 	 sram_ren;

   wire q;

   wire spi_cs;
   wire spi_sck;
   wire spi_copi;
   wire spi_cipo;

    
    assign bidir_out[0] = q;
    
    assign bidir_out[1] = spi_cs;
    assign bidir_out[2] = spi_sck;
    assign bidir_out[3] = spi_copi;

    
    // assign spi_cipo = bidir_in[4];

    assign bidir_out[NUM_BIDIR_PADS-1:5] = '0;


    logic loader_enabled;
    logic [7:0] loader_wdata;
    logic       loader_valid;
    logic       loader_ready;

    logic [7:0] loader01_wdata;
    logic       loader01_valid;
    logic       loader01_ready;

    proc_wrapper u_proc_wrapper0 (
        `ifdef USE_POWER_PINS
        .VDD(VDD),
        .VSS(VSS),
        `endif
        
        .i_clk(clk),     // clock
        .i_rst(rst_n),     // reset (active low)

        .i_loader_en(loader_enabled),

        .i_loader_i_wdata(loader_wdata), // Loader stream interface in data
        .i_loader_i_valid(loader_valid), // Loader stream interface in valid
        .o_loader_i_ready(loader_ready), // Loader stream interface in ready

        .o_loader_o_wdata(loader01_wdata), // Loader stream interface out data
        .o_loader_o_valid(loader01_valid), // Loader stream interface out valid
        .i_loader_o_ready(loader01_ready), // Loader stream interface out ready

        .q()
    );

    proc_wrapper u_proc_wrapper1 (
        `ifdef USE_POWER_PINS
        .VDD(VDD),
        .VSS(VSS),
        `endif
        
        .i_clk(clk),     // clock
        .i_rst(rst_n),     // reset (active low)

        .i_loader_en(loader_enabled),

        .i_loader_i_wdata(loader01_wdata), // Loader stream interface in data
        .i_loader_i_valid(loader01_valid), // Loader stream interface in valid
        .o_loader_i_ready(loader01_ready), // Loader stream interface in ready

        .o_loader_o_wdata(), // Loader stream interface out data
        .o_loader_o_valid(), // Loader stream interface out valid
        .i_loader_o_ready(1'b1), // Loader stream interface out ready

        .q()
    );



    logic rst;
    assign rst = ~rst_n;

    racquet u_racquet (
        .clk(clk), 
        .rst(rst),
    
        .cs(spi_cs), 
        .copi(spi_copi), 
        .cipo(spi_cipo), 
        .sck(spi_sck),

        .loader_enabled(loader_enabled),

        .o_loader_payload(loader_wdata),
        .o_loader_valid(loader_valid),
        .i_loader_ready(loader_ready)
    );

endmodule

`default_nettype wire
