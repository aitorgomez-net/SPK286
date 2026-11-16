// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Real address mode PUSH whose word would start at SS:FFFF. Intel 210498
// section 5.2.3 lists a word operand at offset FFFF as interrupt 13. An Intel
// N80286-12 decrements SP to FFFF,
// writes nothing there, and delivers interrupt 13 below it with CS:IP at the
// PUSH. It does not shut down.
module spk286_real_push_wrap_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "REAL_PUSH_WRAP %s: CS:IP=%h:%h AX=%h SP=%h halted=%b shutdown=%b event=%h",
                       message, debug_cs, debug_ip, debug_gpr[15:0], debug_gpr[79:64], halted, shutdown,
                       debug_event_vector);
        end
    endtask

    function automatic logic [15:0] word_at(input logic [15:0] address);
        word_at = {memory[address + 16'd1], memory[address]};
    endfunction

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

    // 0100: MOV SP,sp / MOV AX,1234 / PUSH AX (0106) / HLT. Interrupt 13
    // goes to 0200: MOV AX,BEEF / HLT.
    task automatic run_case(input logic [15:0] sp);
        integer deadline;
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'hA5;
            memory[16'h0100] = 8'hBC; memory[16'h0101] = sp[7:0]; memory[16'h0102] = sp[15:8];
            memory[16'h0103] = 8'hB8; memory[16'h0104] = 8'h34; memory[16'h0105] = 8'h12;
            memory[16'h0106] = 8'h50;
            memory[16'h0107] = 8'hF4;
            memory[16'h0034] = 8'h00; memory[16'h0035] = 8'h02;
            memory[16'h0036] = 8'h00; memory[16'h0037] = 8'h00;
            memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'hEF; memory[16'h0202] = 8'hBE;
            memory[16'h0203] = 8'hF4;

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
        run_case(16'h0001);
        check(halted && !shutdown && debug_gpr[15:0] == 16'hBEEF, "PUSH at SP=1 takes interrupt 13");
        check(debug_gpr[79:64] == 16'hFFF9, "the faulting PUSH leaves SP=FFFF below which the frame goes");
        check(word_at(16'hFFF9) == 16'h0106 && word_at(16'hFFFB) == 16'h0000 && word_at(16'hFFFD) == 16'h0002,
              "interrupt 13 saves CS:IP of the PUSH and FLAGS");
        check(memory[16'hFFFF] == 8'hA5 && memory[16'h0000] == 8'hA5,
              "the faulting PUSH writes nothing at FFFF or 0000");

        run_case(16'h0003);
        check(halted && !shutdown && debug_gpr[15:0] == 16'h1234 && debug_gpr[79:64] == 16'h0001 &&
              word_at(16'h0001) == 16'h1234, "PUSH at SP=3 writes at 0001 without a fault");

        run_case(16'h0000);
        check(halted && !shutdown && debug_gpr[15:0] == 16'h1234 && debug_gpr[79:64] == 16'hFFFE &&
              word_at(16'hFFFE) == 16'h1234, "PUSH at SP=0 wraps to FFFE without a fault");

        $display("REAL_PUSH_WRAP PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
