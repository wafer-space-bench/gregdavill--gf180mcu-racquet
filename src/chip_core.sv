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

    
    // assign bidir_out[0] = q;
    
    assign bidir_out[1] = spi_cs;
    assign bidir_out[2] = spi_sck;
    assign bidir_out[3] = spi_copi;

    
    // assign spi_cipo = bidir_in[4];

    assign bidir_out[NUM_BIDIR_PADS-1:5] = '0;

    localparam integer NUM_PROC_CORES = 2;
    genvar i;

    logic loader_enabled;
    logic [7:0] loader_wdata[NUM_PROC_CORES + 1];
    logic       loader_valid[NUM_PROC_CORES + 1];
    logic       loader_ready[NUM_PROC_CORES + 1];

    logic [NUM_PROC_CORES-1:0] proc_core_io;

    generate begin
        for (i = 0; i < NUM_PROC_CORES ; i++ ) begin : gen_proc_wrapper
            proc_wrapper u_proc_wrapper (
                `ifdef USE_POWER_PINS
                .VDD(VDD),
                .VSS(VSS),
                `endif
                
                .i_clk(clk),        // clock
                .i_rst(rst_n),      // reset (active low)

                .i_loader_en(loader_enabled),

                // Loader stream interface in
                .i_loader_i_wdata(loader_wdata[i]),
                .i_loader_i_valid(loader_valid[i]),
                .o_loader_i_ready(loader_ready[i]),

                // Loader stream interface out, to next core
                .o_loader_o_wdata(loader_wdata[i+1]),
                .o_loader_o_valid(loader_valid[i+1]),
                .i_loader_o_ready(loader_ready[i+1]),

                .q(proc_core_io[i])
            );
        end
    end
    endgenerate

    // Last core ready signal tied high
    assign loader_ready[NUM_PROC_CORES] = 1'b1;


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

        .o_loader_payload(loader_wdata[0]),
        .o_loader_valid(loader_valid[0]),
        .i_loader_ready(loader_ready[0])
    );

endmodule

`default_nettype wire
