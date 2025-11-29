module wb_queue (
    input logic clk_i,
    input logic rst_n,

    // Write WB port
    input logic        wr_cyc_i,
    input logic        wr_stb_i,
    input logic        wr_we_i,
    input logic [ 3:0] wr_sel_i,
    input logic [11:0] wr_adr_i,
    input logic [31:0] wr_dat_i,

    output logic [31:0] wr_dat_o,
    output logic        wr_ack_o,

    // Read WB port
    input logic        rd_cyc_i,
    input logic        rd_stb_i,
    input logic        rd_we_i,
    input logic [ 3:0] rd_sel_i,
    input logic [11:0] rd_adr_i,
    input logic [31:0] rd_dat_i,

    output logic [31:0] rd_dat_o,
    output logic        rd_ack_o
);

    localparam integer NUM_QUEUES = 8;
    localparam integer NUM_NBLK_QUEUES = 8;

    // Register address map
    localparam logic [9:0] QUEUE0 = 10'h0;
    localparam logic [9:0] NBLK_QUEUE0 = 10'(NUM_QUEUES);

    // Internal registers
    logic [31:0] reg_queue[NUM_QUEUES];
    logic reg_queue_valid[NUM_QUEUES];

    logic [31:0] reg_nblk_queue[NUM_NBLK_QUEUES];
    logic reg_nblk_queue_valid[NUM_NBLK_QUEUES];

    // Address matching
    wire wr_active = wr_cyc_i && wr_stb_i & !wr_ack_o;
    wire rd_active = rd_cyc_i && rd_stb_i & !rd_ack_o;

    integer i;

    // Write port
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            wr_ack_o <= 1'b0;
        end else begin
            if (wr_active) begin
                // Write operation (performed on response cycle)
                if (wr_we_i) begin
                    for (i = 0; i < NUM_QUEUES; i = i + 1)
                    if (wr_adr_i[11:2] == 10'(QUEUE0 + i))
                        wr_ack_o <= !reg_queue_valid[i];

                    for (i = 0; i < NUM_NBLK_QUEUES; i = i + 1)
                    if (wr_adr_i[11:2] == 10'(NBLK_QUEUE0 + i))
                        wr_ack_o <= 1'b1;

                end else begin
                    // Write only port
                end
            end else begin
                wr_ack_o <= 1'b0;
            end
        end
    end
    assign wr_dat_o = '0;

    for (i = 0; i < NUM_QUEUES; i = i + 1) begin
        always_ff @(posedge clk_i or negedge rst_n) begin
            if (!rst_n) begin
                reg_queue[i] <= '0;
                reg_queue_valid[i] <= 1'b0;
            end else begin
                if (wr_active && wr_we_i) begin
                    if (wr_adr_i[11:2] == 10'(QUEUE0 + i)) begin
                        if (!reg_queue_valid[i]) begin
                            for (int b = 0; b < 4; b++) begin
                                if (wr_sel_i[b])
                                    reg_queue[i][b*8+:8] <= wr_dat_i[b*8+:8];
                            end
                            reg_queue_valid[i] <= 1'b1;
                        end
                    end
                end else if (rd_ack_o && (rd_adr_i[11:2] == 10'(QUEUE0 + i))) begin
                    reg_queue_valid[i] <= 1'b0;
                end
            end
        end
    end

    for (i = 0; i < NUM_NBLK_QUEUES; i = i + 1) begin
        always_ff @(posedge clk_i or negedge rst_n) begin
            if (!rst_n) begin
                reg_queue[i] <= '0;
                reg_queue_valid[i] <= 1'b0;
            end else begin
                if (wr_active && wr_we_i) begin
                    if (wr_adr_i[11:2] == 10'(NBLK_QUEUE0 + i)) begin
                        if (!reg_queue_valid[i]) begin
                            for (int b = 0; b < 4; b++) begin
                                if (wr_sel_i[b])
                                    reg_queue[i][b*8+:8] <= wr_dat_i[b*8+:8];
                            end
                            reg_queue_valid[i] <= 1'b1;
                        end
                    end
                end else if (rd_ack_o && (rd_adr_i[11:2] == 10'(NBLK_QUEUE0 + i))) begin
                    reg_queue_valid[i] <= 1'b0;
                end
            end
        end
    end

    // Read port
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            rd_ack_o <= 1'b0;
        end else begin
            if (rd_active) begin
                // Write operation (performed on response cycle)
                if (rd_we_i) begin
                    // RO interface
                end else begin
                    for (i = 0; i < NUM_QUEUES; i = i + 1) begin
                        if (reg_queue_valid[i] && (rd_adr_i[11:2] == 10'(QUEUE0 + i))) begin
                            rd_dat_o <= reg_queue[i];
                            rd_ack_o <= 1'b1;
                        end
                    end
                    for (i = 0; i < NUM_NBLK_QUEUES; i = i + 1) begin
                        if (reg_nblk_queue_valid[i] && (rd_adr_i[11:2] == 10'(NBLK_QUEUE0 + i))) begin
                            rd_dat_o <= reg_nblk_queue[i];
                            rd_ack_o <= 1'b1;
                        end
                    end
                end
            end else begin
                rd_ack_o <= 1'b0;
            end
        end
    end

endmodule
