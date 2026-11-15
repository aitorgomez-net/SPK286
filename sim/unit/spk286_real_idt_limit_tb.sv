// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Real address mode, Intel 210498 section 5.2.3: "Interrupt Table Limit Too
// Small (Interrupt 8). This interrupt will occur if the limit of the interrupt
// vector table was changed from 3FFH by the LIDT instruction and an interrupt
// whose vector is outside the limit occurs. The saved value of CS:IP will point
// to the first byte of the instruction that caused the interrupt ... No error
// code is pushed." A vector 8 that is itself outside the limit has nowhere to
// go and shuts the processor down.
module spk286_real_idt_limit_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "REAL_IDT_LIMIT %s: CS:IP=%h:%h AX=%h SP=%h halted=%b shutdown=%b event=%h",
                       message, debug_cs, debug_ip, debug_gpr[15:0], debug_gpr[79:64], halted, shutdown,
                       debug_event_vector);
        end
    endtask

    task automatic write_word(input integer address, input logic [15:0] value);
        begin
            memory[address] = value[7:0];
            memory[address + 1] = value[15:8];
        end
    endtask

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    // LIDT with the given limit (unless it is the reset value), then INT n.
    task automatic run_case(input logic load, input logic [15:0] limit, input logic [7:0] vector);
        integer deadline;
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;
            // 0100: [LIDT [0300]] / MOV SP,6000 / INT n / HLT
            memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h1E;
            memory[16'h0103] = 8'h00; memory[16'h0104] = 8'h03;
            if (!load) for (integer i = 32'h0100; i < 32'h0105; i = i + 1) memory[i] = 8'h90;
            memory[16'h0105] = 8'hBC; memory[16'h0106] = 8'h00; memory[16'h0107] = 8'h60;
            memory[16'h0108] = 8'hCD; memory[16'h0109] = vector;
            memory[16'h010A] = 8'hF4;
            write_word(32'h0300, limit);
            // Handlers: the requested vector loads DEAD, vector 8 loads BEEF.
            write_word({22'd0, vector, 2'b00}, 16'h0280);
            write_word(32'h0020, 16'h0200);
            memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'hEF; memory[16'h0202] = 8'hBE; memory[16'h0203] = 8'hF4;
            memory[16'h0280] = 8'hB8; memory[16'h0281] = 8'hAD; memory[16'h0282] = 8'hDE; memory[16'h0283] = 8'hF4;

            reset = 1'b1; execute_enable = 1'b0;
            repeat (4) tick();
            reset = 1'b0;
            segment_load_en = 1'b1; segment_load_index = 2'd1; segment_load_selector = 16'h0000;
            ip_write_en = 1'b1; ip_write_data = 16'h0100; redirect = 1'b1;
            tick();
            segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            deadline = 0;
            while (!halted && !shutdown && deadline < 3000) begin
                tick();
                deadline = deadline + 1;
            end
            check(deadline < 3000, "bounded execution");
        end
    endtask

    initial begin
        // Reset limit 3FFh: every vector has its entry.
        run_case(1'b0, 16'h0000, 8'd9);
        check(halted && !shutdown && debug_gpr[15:0] == 16'hDEAD, "reset limit delivers the requested vector");
        run_case(1'b0, 16'h0000, 8'd255);
        check(halted && !shutdown && debug_gpr[15:0] == 16'hDEAD, "reset limit covers vector 255");

        // Limit 27h holds vectors 0 to 9 exactly: the last byte of entry 9 is 27h.
        run_case(1'b1, 16'h0027, 8'd9);
        check(halted && !shutdown && debug_gpr[15:0] == 16'hDEAD, "an entry that ends at the limit is delivered");

        // One byte less and entry 9 is outside: interrupt 8, with no error code
        // and the address of the INT instruction itself.
        run_case(1'b1, 16'h0026, 8'd9);
        check(halted && !shutdown && debug_gpr[15:0] == 16'hBEEF, "a vector outside the limit takes interrupt 8");
        check(debug_gpr[79:64] == 16'h5FFA, "interrupt 8 pushes FLAGS, CS and IP and no error code");
        check({memory[16'h5FFB], memory[16'h5FFA]} == 16'h0108 && {memory[16'h5FFD], memory[16'h5FFC]} == 16'h0000,
              "interrupt 8 saves the address of the instruction that caused it");

        // Limit 23h holds vector 8 exactly; 22h does not, and there is no way out.
        run_case(1'b1, 16'h0023, 8'd9);
        check(halted && !shutdown && debug_gpr[15:0] == 16'hBEEF, "vector 8 at the limit is delivered");
        run_case(1'b1, 16'h0022, 8'd9);
        check(shutdown && debug_gpr[15:0] != 16'hBEEF && debug_gpr[15:0] != 16'hDEAD,
              "interrupt 8 outside the limit shuts down");
        run_case(1'b1, 16'h0000, 8'd3);
        check(shutdown, "limit 0 shuts down on any interrupt");

        $display("REAL_IDT_LIMIT PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
