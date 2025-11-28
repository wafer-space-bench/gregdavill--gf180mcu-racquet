// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module proc_wrapper (
    `ifdef USE_POWER_PINS
    inout logic VDD,
    inout logic VSS,
    `endif
    
    input  logic i_clk,     // clock
    input  logic i_rst,     // reset (active low)

    input logic        i_loader_en,

    input  logic [7:0] i_loader_i_wdata, // Loader stream interface in data
    input  logic       i_loader_i_valid, // Loader stream interface in valid
    output logic       o_loader_i_ready, // Loader stream interface in ready

    output logic [7:0] o_loader_o_wdata, // Loader stream interface out data
    output logic       o_loader_o_valid, // Loader stream interface out valid
    input  logic       i_loader_o_ready, // Loader stream interface out ready

    output logic q
    
);

   parameter memsize = 512;
   localparam aw    = $clog2(memsize);

   logic [aw-1:0] proc_sram_waddr;
   logic [7:0]    proc_sram_wdata;
   logic 	      proc_sram_wen;
   logic [aw-1:0] proc_sram_raddr;
   logic [7:0]    proc_sram_rdata;
   logic 	      proc_sram_ren;

   logic [aw-1:0] loader_sram_waddr;
   logic [7:0]    loader_sram_wdata;
   logic 	      loader_sram_wen;

   logic [aw-1:0] sram_addr;
   logic 	      sram_cen;
   logic 	      sram_wen;
   logic [7:0]    sram_wdata;
   logic [7:0]    sram_rdata;


    logic spi_copi;
    logic spi_cipo;
    logic spi_sck;
    logic spi_cs;


    logic proc_rst;

    // Loader FSM
    typedef enum logic [1:0] {LOAD, BYPASS, RUN} state_t;
    state_t state, next_state;
    logic [aw-1:0] load_addr_reg;

    // FSM state
    always_ff @(posedge i_clk or negedge i_rst) begin
        if (!i_rst) begin
            state <= LOAD;
        end else begin
            state <= next_state;
        end
    end

    always_ff @(posedge i_clk or negedge i_rst) begin
        if (!i_rst) begin
            load_addr_reg = '0;
        end else begin
            if ((state == LOAD) && i_loader_i_valid && o_loader_i_ready) begin
                load_addr_reg <= load_addr_reg + 8'd1;
            end
            else if(state == RUN && next_state == LOAD) begin
                load_addr_reg <= '0;
            end
        end
    end

    always_ff @(posedge i_clk or negedge i_rst) begin
        if (!i_rst) begin
            proc_rst <= 1'b1;
        end else begin
            if (next_state == RUN) begin
                proc_rst <= 1'b0;
            end
        end
    end

    // FSM logic
    always_comb begin
        loader_sram_wen  = 1'b0;
        loader_sram_waddr = load_addr_reg;
        loader_sram_wdata = i_loader_i_wdata;
        o_loader_i_ready = 1'b0;

        next_state = state;


        // Default  SRAM to proc
        sram_addr = proc_sram_wen ? proc_sram_waddr : proc_sram_raddr;
        sram_cen = proc_rst;
        sram_wen = ~proc_sram_wen;
        sram_wdata = proc_sram_wdata;
        proc_sram_rdata = sram_rdata;

        
        case (state)
            LOAD: begin
                o_loader_i_ready = 1'b1; // accept loader data
                if (i_loader_i_valid && o_loader_i_ready) begin
                    loader_sram_wen = 1'b1;

                    // if we've written the last address, transition to RUN next cycle
                    if (load_addr_reg == memsize - 1) begin
                        next_state = BYPASS;
                    end
                end

                // connect SRAM to loader
                sram_addr = loader_sram_waddr;
                sram_cen = ~loader_sram_wen;
                sram_wen = ~loader_sram_wen;
                sram_wdata = loader_sram_wdata;
            end

            BYPASS: begin
                o_loader_o_wdata = i_loader_i_wdata;
                o_loader_o_valid = i_loader_i_valid;
                o_loader_i_ready = i_loader_o_ready;

                if(i_loader_en == 0) begin
                    next_state = RUN;
                end
            end

            RUN: begin
                if(i_loader_en == 1) begin
                    next_state = LOAD;
                end
            end

            default: begin
                state = LOAD;
            end
        endcase
    end



    subservient
        #(.memsize  (memsize),
        .WITH_CSR (0))
    u_proc
        (// Clock & reset
        .i_clk (i_clk),
        .i_rst (proc_rst),

        //SRAM interface
        .o_sram_waddr (proc_sram_waddr),
        .o_sram_wdata (proc_sram_wdata),
        .o_sram_wen   (proc_sram_wen),
        .o_sram_raddr (proc_sram_raddr),
        .i_sram_rdata (proc_sram_rdata),
        .o_sram_ren   (proc_sram_ren),

        // External I/O
        .o_gpio (q)
    );

    // Single Port FSM
    gf180mcu_fd_ip_sram__sram512x8m8wm1 u_sram (
        `ifdef USE_POWER_PINS
        .VDD  (VDD),
        .VSS  (VSS),
        `endif

        .CLK  (i_clk),
        .CEN  (sram_cen),
        .GWEN (sram_wen),
        .WEN  ({8{sram_wen}}),
        .A    (sram_addr),
        .D    (sram_wdata),
        .Q    (sram_rdata)
    );

endmodule

`default_nettype wire
