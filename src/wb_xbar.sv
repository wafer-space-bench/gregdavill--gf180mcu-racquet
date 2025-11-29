
module wb_xbar #(
    parameter integer NUM_MASTERS = 2,
    parameter integer NUM_SLAVES  = 8,
    parameter integer DATA_WIDTH  = 32,
    parameter integer ADDR_WIDTH  = 32,
    // SEL_WIDTH should equal DATA_WIDTH/8 for byte-selects
    parameter integer SEL_WIDTH   = (DATA_WIDTH / 8)
) (
    input logic clk,
    input logic rst_n,

    // Controllers
    input  logic [ADDR_WIDTH-1:0] m_adr_i[NUM_MASTERS],
    input  logic [DATA_WIDTH-1:0] m_dat_i[NUM_MASTERS],  // master's write data
    input  logic [ SEL_WIDTH-1:0] m_sel_i[NUM_MASTERS],
    input  logic                  m_we_i [NUM_MASTERS],
    input  logic                  m_stb_i[NUM_MASTERS],
    input  logic                  m_cyc_i[NUM_MASTERS],
    output logic [DATA_WIDTH-1:0] m_dat_o[NUM_MASTERS],  // master's read data
    output logic                  m_ack_o[NUM_MASTERS],
    output logic                  m_err_o[NUM_MASTERS],

    // Responders
    output logic [          11:0] s_adr_o[NUM_SLAVES],
    output logic [DATA_WIDTH-1:0] s_dat_o[NUM_SLAVES],  // write data to slave
    output logic [ SEL_WIDTH-1:0] s_sel_o[NUM_SLAVES],
    output logic                  s_we_o [NUM_SLAVES],
    output logic                  s_stb_o[NUM_SLAVES],
    output logic                  s_cyc_o[NUM_SLAVES],
    // Each slave sees a 12-bit offset into its 4KB region
    input  logic [DATA_WIDTH-1:0] s_dat_i[NUM_SLAVES],  // read data from slave
    input  logic                  s_ack_i[NUM_SLAVES],
    input  logic                  s_err_i[NUM_SLAVES]
);

    // Parameter sanity
    initial begin
        if (ADDR_WIDTH < 12) begin
            $display(
                "ERROR: ADDR_WIDTH must be >= 12 (we use 12-bit offsets for 4KB windows).");
            $finish;
        end
        if (NUM_SLAVES > (1 << (ADDR_WIDTH - 12))) begin
            $display(
                "ERROR: NUM_SLAVES (%0d) exceeds addressability for ADDR_WIDTH=%0d (max %0d).",
                NUM_SLAVES, ADDR_WIDTH, (1 << (ADDR_WIDTH - 12)));
            $finish;
        end
    end

    // Local functions
    function integer clog2;
        input integer val;
        integer i;
        begin
            clog2 = 0;
            for (i = val - 1; i > 0; i = i >> 1) clog2 = clog2 + 1;
        end
    endfunction

    localparam integer OFFSET_BITS = 12;  // 4KB window
    localparam integer SLAVE_INDEX_BITS = (ADDR_WIDTH > OFFSET_BITS) ? (ADDR_WIDTH - OFFSET_BITS) : 1;
    localparam integer GRANT_PTR_BITS = (NUM_MASTERS > 1) ? clog2(
        NUM_MASTERS
    ) : 1;

    // Per-master decoded slave index and request signals
    // We'll extract per-master slices in generate loops
    logic [NUM_MASTERS-1:0] m_req;  // master requests (cyc & stb)
    logic [SLAVE_INDEX_BITS-1:0] m_slave_idx[NUM_MASTERS];
    logic m_slave_share[NUM_MASTERS];


    genvar i;
    generate
        for (i = 0; i < NUM_MASTERS; i = i + 1) begin : EXTRACT_MASTER_BUNDLES
            // compute slave index (high bits above offset)
            if (ADDR_WIDTH > OFFSET_BITS) begin : SLICE_IDX
                // slice of m_adr_arr[i] from ADDR_WIDTH-1 downto OFFSET_BITS
                assign m_slave_idx[i] = {
                    2'b00, m_adr_i[i][ADDR_WIDTH-3:OFFSET_BITS]
                };
                assign m_slave_share[i] = m_adr_i[i][ADDR_WIDTH-1];
            end else begin : ZERO_IDX
                assign m_slave_idx[i]   = {SLAVE_INDEX_BITS{1'b0}};
                assign m_slave_share[i] = 1'b0;
            end
        end
    endgenerate

    // request signal: master wants access and is asserting cyc+stb
    generate
        for (i = 0; i < NUM_MASTERS; i = i + 1) begin : REQ_PACK
            assign m_req[i] = m_cyc_i[i] & m_stb_i[i];
        end
    endgenerate

    // Per-slave arbitration:
    // - compute req vector (which masters target this slave)
    // - pick a granted master with round-robin fairness
    // - forward the granted master's bus to the slave
    integer j, k, m, s;
    reg [NUM_MASTERS-1:0] req_vector[NUM_SLAVES];
    reg [NUM_MASTERS-1:0] req_vector_share[NUM_SLAVES];
    reg [NUM_MASTERS-1:0] grant_vector[NUM_SLAVES];
    reg grant_valid[NUM_SLAVES];

    // Build req vectors (combinational)
    always_comb begin
        for (j = 0; j < NUM_SLAVES; j = j + 1) begin
            req_vector[j] = {NUM_MASTERS{1'b0}};
            req_vector_share[j] = {NUM_MASTERS{1'b0}};
            for (k = 0; k < NUM_MASTERS; k = k + 1) begin
                // compare master k's decoded index to slave j
                if (m_req[k] && (m_slave_idx[k] == 20'(j)))
                    req_vector[j][k] = 1'b1;
                if (m_req[k] && (m_slave_idx[k] == 20'(j)) && m_slave_share[k])
                    req_vector_share[j][k] = 1'b1;
            end
        end
    end

    // Simple fixed-priority arbiter: lower-numbered master has higher priority.
    integer m_idx;
    always_comb begin
        for (j = 0; j < NUM_SLAVES; j = j + 1) begin
            grant_vector[j] = {NUM_MASTERS{1'b0}};
            grant_valid[j]  = 1'b0;
            if (NUM_MASTERS == 1) begin
                if (req_vector[j][0]) begin
                    grant_vector[j][0] = 1'b1;
                    grant_valid[j] = 1'b1;
                end
            end else begin
                // fixed priority: pick lowest numbered master that is requesting
                for (m_idx = 0; m_idx < NUM_MASTERS; m_idx = m_idx + 1) begin
                    if (req_vector[j][m_idx] && !grant_valid[j]) begin
                        grant_vector[j][m_idx] = 1'b1;
                        grant_valid[j] = 1'b1;
                    end
                    if (req_vector_share[j][m_idx]) begin
                        grant_vector[j][m_idx] = 1'b1;
                        grant_valid[j] = 1'b1;
                    end
                end
            end
        end
    end

    logic [NUM_SLAVES-1:0] any_grant;
    // Drive slave-side outputs by multiplexing the granted master's signals
    always_comb begin
        // default zeros

        for (j = 0; j < NUM_SLAVES; j = j + 1) begin
            s_cyc_o[j] = '0;
            s_stb_o[j] = '0;
            s_we_o[j] = '0;
            s_sel_o[j] = '0;
            s_adr_o[j] = '0;
            s_dat_o[j] = '0;

            // if someone is granted, forward that master's signals
            any_grant[j] = 1'b0;
            for (m = 0; m < NUM_MASTERS; m = m + 1) begin
                if (grant_vector[j][m]) begin
                    any_grant[j] = 1'b1;

                    // assign to slave j slices
                    // s_cyc/stb/we
                    s_cyc_o[j] = m_cyc_i[m];
                    s_stb_o[j] = m_stb_i[m];
                    s_we_o[j] = m_we_i[m];

                    // SEL
                    s_sel_o[j] = m_sel_i[m];

                    // address passed as offset within 4KB window: lower 12 bits of master's address
                    s_adr_o[j] = OFFSET_BITS'(m_adr_i[m]);

                    // write data
                    s_dat_o[j] = m_dat_i[m];
                end
            end
            // If no grant, signals remain zero (slave idle)
        end
    end

    logic [NUM_MASTERS-1:0] got_grant;
    // Drive master-side responses (ack, err, read-data)
    always_comb begin
        // defaults

        for (k = 0; k < NUM_MASTERS; k = k + 1) begin
            m_dat_o[k]   = '0;
            m_ack_o[k]   = '0;
            m_err_o[k]   = '0;

            // find which slave (if any) currently grants this master
            got_grant[k] = 1'b0;
            for (s = 0; s < NUM_SLAVES; s = s + 1) begin
                if (grant_vector[s][k]) begin
                    got_grant[k] = 1'b1;
                    // connect slave response to master k
                    m_dat_o[k]   = s_dat_i[s];
                    m_ack_o[k]   = s_ack_i[s];
                    m_err_o[k]   = s_err_i[s];
                end
            end
            // If not granted, ack/err remain 0 and dat_o stays 0
        end
    end

endmodule
