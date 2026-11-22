`timescale 1ns/1ps

// Vector-driven test, checked against scripts/reference_model.py instead of
// a reference written inside the testbench.
//
// Drives seq_matmul by default. Compile with -DSYSTOLIC to drive
// systolic_accelerator_top instead; both have the same ports.
//
// For every job in sim/vectors (12 directed + 100 random):
//   - c_flat must equal the model's result while done = 1
//   - start -> done latency must be exactly LAT (counted as tb_accelerator_top does)
//   - done must last exactly one cycle
//   - a_flat/b_flat are scrambled right after LOAD, so a design that reads
//     its inputs after LOAD instead of the latched copy fails
//   - start pulses that arrive while the design is busy must be ignored:
//     job % 4 == 3 pulses start during the compute phase,
//     job % 4 == 1 pulses start in the last busy cycle (CAPTURE on the
//     systolic top), job % 4 == 2 pulses start while done is high
//   - exactly EXPECTED_JOBS jobs must run, so a missing vector file fails
// Jobs run back to back with no reset. Run from the repo root.
module tb_matmul_vectors;
`ifdef SYSTOLIC
    localparam LAT = 10;            // sample start, LOAD, COMPUTE 7, CAPTURE
`else
    localparam LAT = 29;            // sample start, LOAD, COMPUTE 27
`endif
    localparam MAX_JOBS = 112;
    parameter  EXPECTED_JOBS = 112;

    reg          clk = 0, reset = 1, start = 0;
    reg  [71:0]  a_flat = 0, b_flat = 0;
    wire         done;
    wire [287:0] c_flat;

`ifdef SYSTOLIC
    systolic_accelerator_top dut (
`else
    seq_matmul dut (
`endif
        .clk(clk), .reset(reset), .start(start),
        .a_flat(a_flat), .b_flat(b_flat),
        .done(done), .c_flat(c_flat)
    );

    reg [71:0]  va [0:MAX_JOBS-1];
    reg [71:0]  vb [0:MAX_JOBS-1];
    reg [287:0] vc [0:MAX_JOBS-1];

    integer errors = 0, jobs = 0, cycles, e, n, done_len;
    reg [8*64-1:0] dump;

    always #5 clk = ~clk;

    task run_job(input integer idx);
        begin
            @(negedge clk);
            a_flat = va[idx]; b_flat = vb[idx]; start = 1;
            @(posedge clk); cycles = 1;                 // start sampled
            @(negedge clk) start = 0;
            @(posedge clk); cycles = cycles + 1;        // LOAD edge, inputs latched
            @(negedge clk);
            a_flat = ~va[idx]; b_flat = {b_flat[35:0], b_flat[71:36]};
            if (idx % 4 == 3) start = 1;                // must be ignored
            @(negedge clk) start = 0;
            cycles = cycles + 1;
            while (!done && cycles < LAT + 40) begin
                // job % 4 == 1: start high when the last busy cycle is sampled
                start = (idx % 4 == 1) && (cycles == LAT - 1);
                @(posedge clk); cycles = cycles + 1; #1;
            end
            start = 0;
            jobs = jobs + 1;
            if (cycles != LAT) begin
                errors = errors + 1;
                $display("FAIL job %0d: latency %0d, expected %0d", idx, cycles, LAT);
            end
            for (e = 0; e < 9; e = e + 1)
                if (c_flat[e*32 +: 32] !== vc[idx][e*32 +: 32]) begin
                    errors = errors + 1;
                    $display("FAIL job %0d: C[%0d][%0d] = %0d, expected %0d", idx, e / 3, e % 3,
                             $signed(c_flat[e*32 +: 32]), $signed(vc[idx][e*32 +: 32]));
                end
            done_len = 0;
            start = (idx % 4 == 2);                     // sampled while done is high
            while (done && done_len < 5) begin
                @(posedge clk); #1; done_len = done_len + 1;
                start = 0;
            end
            if (done_len != 1) begin
                errors = errors + 1;
                $display("FAIL job %0d: done high for %0d cycles", idx, done_len);
            end
            // A start pulse that arrived while busy must not have queued a job.
            repeat (LAT + 2) begin
                @(posedge clk); #1;
                if (done) begin
                    errors = errors + 1;
                    $display("FAIL job %0d: extra done without a start", idx);
                end
            end
        end
    endtask

    initial begin
        $readmemh("sim/vectors/jobs_a.hex", va);
        $readmemh("sim/vectors/jobs_b.hex", vb);
        $readmemh("sim/vectors/jobs_c.hex", vc);
        if ($value$plusargs("vcd=%s", dump)) begin
            $dumpfile(dump);
            $dumpvars(0, tb_matmul_vectors);
        end
        repeat (3) @(posedge clk);
        #1 reset = 0;

        for (n = 0; n < MAX_JOBS; n = n + 1)
            if (va[n] !== 72'bx) run_job(n);

        $display("jobs=%0d errors=%0d latency=%0d cycles", jobs, errors, LAT);
        if (jobs != EXPECTED_JOBS) begin
            errors = errors + 1;
            $display("FAIL: ran %0d jobs, expected %0d (missing or short vector files?)",
                     jobs, EXPECTED_JOBS);
        end
        if (errors == 0) $display("VECTOR TESTS PASSED");
        else $fatal(1, "VECTOR TESTS FAILED");
        $finish;
    end
endmodule
