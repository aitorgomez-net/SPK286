// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Protected-mode POPA and ENTER against an SS limit of FFh, as an Intel
// N80286-12 does them:
// - POPA checks all eight words before reading any: with SP=FEh it raises
//   #SS(0) and leaves SP and every register unchanged;
// - ENTER checks the word at its final SP: ENTER 8,0 with SP=2 writes BP at
//   SS:0, then raises #SS(0) and leaves SP and BP unchanged.
module spk286_protected_stack_block_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0, stack_reads = 0;
    logic observe = 0, fault_seen = 0;
    logic [7:0] first_fault_vector = 0;
    logic [15:0] first_fault_error = 0;
    localparam integer STACK_BASE = 'hD000;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "PROTECTED_STACK_BLOCK %s case=%0d CS:IP=%h:%h SP=%h BP=%h DI=%h AX=%h fault=%h/%h reads=%0d",
                   message, cases, debug_cs, debug_ip, debug_gpr[79:64], debug_gpr[95:80], debug_gpr[127:112],
                   debug_gpr[15:0], first_fault_vector, first_fault_error, stack_reads);
    endtask

    task automatic tick;
        #1;
        if (observe && dut.fault_request && !fault_seen) begin
            fault_seen = 1;
            first_fault_vector = dut.fault_vector;
            first_fault_error = dut.fault_error_code;
        end
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]], 8'd0};
            else if (bus_bhe_n) data_in = {8'd0, memory[address[15:0]]};
            else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
        end
        if (observe && bus_valid && ready && bus_status == 5 && address[15:12] == 4'hD) stack_reads = stack_reads + 1;
        if (bus_valid && ready && bus_write && bus_status == 6) begin
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
            end
        end
        #4; clk = 1; #5; clk = 0; #1; cycles = cycles + 1;
    endtask

    task automatic word_put(input integer addr, input logic [15:0] value);
        memory[addr & 65535] = value[7:0]; memory[(addr + 1) & 65535] = value[15:8];
    endtask
    function automatic logic [15:0] word_at(input integer addr);
        word_at = {memory[(addr + 1) & 65535], memory[addr & 65535]};
    endfunction
    task automatic cache(input integer addr, input logic [15:0] base_addr,
                         input logic [15:0] limit_value, input logic [7:0] access_byte);
        word_put(addr, base_addr); word_put(addr + 2, {access_byte, 8'd0}); word_put(addr + 4, limit_value);
    endtask

    // LOADALL into protected mode at CPL 0 with SS base D000h and limit FFh,
    // then run the instruction at 0100h, followed by HLT.
    task automatic run_case(input logic [15:0] sp, input logic [15:0] bp);
        integer deadline;
        reset = 1; execute_enable = 0; observe = 0;
        repeat (4) tick();
        for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 0;
        for (integer i = 0; i < 256; i = i + 1) memory[STACK_BASE + i] = 8'(i ^ 'h5A);
        fault_seen = 0; first_fault_vector = 0; first_fault_error = 0; stack_reads = 0;
        memory['h40] = 8'h0F; memory['h41] = 8'h05;
        word_put('h806, 1); word_put('h816, 16'h0028); word_put('h818, 16'h0002); word_put('h81A, 16'h0100);
        word_put('h81E, 16'h0010); word_put('h820, 16'h0018); word_put('h822, 16'h0008); word_put('h824, 16'h0010);
        word_put('h826, 16'hA590); word_put('h828, 16'h1111); word_put('h82A, bp); word_put('h82C, sp);
        word_put('h82E, 16'h3333); word_put('h830, 16'h4444); word_put('h832, 16'h5555); word_put('h834, 16'h6666);
        cache('h836, 0, 16'hFFFF, 8'h93);
        cache('h83C, 0, 16'hFFFF, 8'h9B);
        cache('h842, 16'(STACK_BASE), 16'h00FF, 8'h93);
        cache('h848, 0, 16'hFFFF, 8'h93);
        cache('h84E, 16'h4000, 16'h003F, 0);
        cache('h85A, 16'h5000, 16'h0107, 0);
        cache('h860, 16'h6000, 16'h002B, 8'h83);
        reset = 0; segment_load_en = 1; segment_load_index = 1; segment_load_selector = 0;
        ip_write_en = 1; ip_write_data = 16'h0040; redirect = 1;
        tick(); segment_load_en = 0; ip_write_en = 0; redirect = 0; execute_enable = 1;
        deadline = 0;
        while (!(debug_cs == 16'h0008 && debug_ip == 16'h0100) && deadline < 2000) begin tick(); deadline = deadline + 1; end
        check(deadline < 2000, "LOADALL enters protected mode at 0008:0100");
        observe = 1; deadline = 0;
        while (!fault_seen && !halted && !shutdown && deadline < 2000) begin tick(); deadline = deadline + 1; end
        check(deadline < 2000 && !shutdown, "bounded execution");
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 0;

        // POPA with SP=FEh: the second word is past the limit.
        memory['h100] = 8'h61; memory['h101] = 8'hF4;
        run_case(16'h00FE, 16'h2222);
        check(fault_seen && first_fault_vector == 12 && first_fault_error == 0, "POPA past the SS limit raises #SS(0)");
        check(debug_gpr == {16'hA590, 16'h1111, 16'h2222, 16'h00FE, 16'h3333, 16'h4444, 16'h5555, 16'h6666} &&
              debug_instruction_ip == 16'h0100 && stack_reads == 0, "a failed POPA reads nothing and changes no register");
        cases = cases + 1;

        // POPA with SP=F0h: all eight words fit.
        run_case(16'h00F0, 16'h2222);
        check(!fault_seen && halted && debug_gpr[79:64] == 16'h0100 &&
              debug_gpr[127:112] == word_at(STACK_BASE + 'hF0) && debug_gpr[15:0] == word_at(STACK_BASE + 'hFE),
              "POPA that fits loads every register");
        cases = cases + 1;

        // ENTER 8,0 with SP=2: BP is written at SS:0, the final SP wraps to FFF8h.
        memory['h100] = 8'hC8; memory['h101] = 8'h08; memory['h102] = 8'h00; memory['h103] = 8'h00; memory['h104] = 8'hF4;
        run_case(16'h0002, 16'h0002);
        check(fault_seen && first_fault_vector == 12 && first_fault_error == 0, "ENTER past the SS limit raises #SS(0)");
        check(debug_gpr[79:64] == 16'h0002 && debug_gpr[95:80] == 16'h0002 && debug_instruction_ip == 16'h0100,
              "a failed ENTER leaves SP and BP unchanged");
        check(word_at(STACK_BASE) == 16'h0002, "a failed ENTER keeps its BP write");
        cases = cases + 1;

        // ENTER 8,0 with SP=20h fits.
        run_case(16'h0020, 16'h0002);
        check(!fault_seen && halted && debug_gpr[79:64] == 16'h0016 && debug_gpr[95:80] == 16'h001E &&
              word_at(STACK_BASE + 'h1E) == 16'h0002, "ENTER that fits allocates its frame");
        cases = cases + 1;

        $display("PROTECTED_STACK_BLOCK PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
