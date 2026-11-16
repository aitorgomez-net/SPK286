// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Real-mode event ordering as an Intel N80286-12 does it. Intel 210498 leaves
// these open:
// - a POPF that sets IF delays INTR by one instruction, like STI;
// - the STI shadow of a REP covers only the boundary before its first
//   iteration;
// - the iteration that exhausts CX still ends at an event boundary, with IP
//   at the REP and CX=0;
// - real-mode interrupts read their vector from the IDTR base.
module spk286_real_event_order_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    integer pc;
    integer acks;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "REAL_EVENT_ORDER %s: CS:IP=%h:%h AX=%h BX=%h CX=%h SI=%h DI=%h SP=%h saved IP=%h acks=%0d",
                       message, debug_cs, debug_ip, debug_gpr[15:0], debug_gpr[63:48], debug_gpr[31:16],
                       debug_gpr[111:96], debug_gpr[127:112], debug_gpr[79:64], word_at(16'h5FFA), acks);
        end
    endtask

    function automatic logic [15:0] word_at(input logic [15:0] address);
        word_at = {memory[address + 16'd1], memory[address]};
    endfunction

    task automatic emit(input logic [7:0] value);
        begin
            memory[pc] = value;
            pc = pc + 1;
        end
    endtask

    task automatic emit_word(input logic [15:0] value);
        begin
            emit(value[7:0]);
            emit(value[15:8]);
        end
    endtask

    task automatic put_word(input integer address, input logic [15:0] value);
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
            if (bus_valid && bus_status == 4'h0) data_in = 16'h0020;
            else if (bus_valid && !bus_write) begin
                if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_status == 4'h0) begin
                acks = acks + 1;
                intr = 1'b0;
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

    // Clear memory, install the handlers and start the program at 0100.
    // INTR (vector 20h) loads BEEF, the TF trap DEAD, INT 3 through the IVT at
    // 0 0BAD and through the relocated table at 9000h 1234; each then halts.
    task automatic begin_program;
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;
            put_word(32'h0080, 16'h0300); put_word(32'h0004, 16'h0280);
            put_word(32'h000C, 16'h03C0); put_word(32'h900C, 16'h0380);
            memory[16'h0300] = 8'hB8; put_word(32'h0301, 16'hBEEF); memory[16'h0303] = 8'hF4;
            memory[16'h0280] = 8'hB8; put_word(32'h0281, 16'hDEAD); memory[16'h0283] = 8'hF4;
            memory[16'h03C0] = 8'hB8; put_word(32'h03C1, 16'h0BAD); memory[16'h03C3] = 8'hF4;
            memory[16'h0380] = 8'hB8; put_word(32'h0381, 16'h1234); memory[16'h0383] = 8'hF4;
            for (integer i = 0; i < 16; i = i + 1) memory[32'h0400 + i] = 8'(32'h0040 + i);
            pc = 32'h0100;
            emit(8'hBC); emit_word(16'h6000);           // MOV SP,6000
        end
    endtask

    task automatic run_program(input logic pending_intr);
        integer deadline;
        begin
            emit(8'hF4);
            acks = 0;
            reset = 1'b1; execute_enable = 1'b0; intr = 1'b0;
            repeat (4) tick();
            reset = 1'b0;
            segment_load_en = 1'b1; segment_load_index = 2'd1; segment_load_selector = 16'h0000;
            ip_write_en = 1'b1; ip_write_data = 16'h0100; redirect = 1'b1;
            tick();
            segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            intr = pending_intr;
            deadline = 0;
            while (!halted && !shutdown && deadline < 4000) begin
                tick();
                deadline = deadline + 1;
            end
            check(deadline < 4000 && !shutdown, "bounded execution");
        end
    endtask

    task automatic emit_string_setup(input logic [15:0] count);
        begin
            emit(8'hB9); emit_word(count);              // MOV CX,count
            emit(8'hBE); emit_word(16'h0400);           // MOV SI,0400
            emit(8'hBF); emit_word(16'h0500);           // MOV DI,0500
        end
    endtask

    integer marker;

    initial begin
        // POPF that sets IF: INTR waits for the next instruction.
        begin_program();
        emit(8'h68); emit_word(16'h0202); emit(8'h9D);  // PUSH 0202 / POPF
        emit(8'h43); marker = pc; emit(8'h41);          // INC BX / INC CX
        run_program(1'b1);
        check(debug_gpr[15:0] == 16'hBEEF && acks == 2, "INTR is taken with two INTA cycles");
        check(word_at(16'h5FFA) == 16'(marker) && debug_gpr[63:48] == 16'd1 && debug_gpr[31:16] == 16'd0,
              "a POPF that sets IF delays INTR by one instruction");

        // POPF that sets TF and IF: the trap after the next instruction wins.
        begin_program();
        emit(8'h68); emit_word(16'h0302); emit(8'h9D);
        emit(8'h43); marker = pc; emit(8'h41);
        run_program(1'b1);
        check(debug_gpr[15:0] == 16'hDEAD && acks == 0 && word_at(16'h5FFA) == 16'(marker),
              "with TF and IF set together the single-step trap comes first");

        // STI then REP MOVSB: INTR after the first iteration, IP at the REP.
        begin_program();
        emit_string_setup(16'd3); emit(8'hFB); marker = pc; emit(8'hF3); emit(8'hA4); emit(8'h43);
        run_program(1'b1);
        check(debug_gpr[15:0] == 16'hBEEF && word_at(16'h5FFA) == 16'(marker) &&
              debug_gpr[31:16] == 16'd2 && debug_gpr[111:96] == 16'h0401 && debug_gpr[127:112] == 16'h0501 &&
              memory[16'h0500] == 8'h40 && memory[16'h0501] == 8'h00,
              "the STI shadow covers only the boundary before the first iteration");

        begin_program();
        emit_string_setup(16'd1); emit(8'hFB); marker = pc; emit(8'hF3); emit(8'hA4); emit(8'h43);
        run_program(1'b1);
        check(debug_gpr[15:0] == 16'hBEEF && word_at(16'h5FFA) == 16'(marker) && debug_gpr[31:16] == 16'd0 &&
              debug_gpr[63:48] == 16'd0, "INTR after the last iteration saves IP at the REP with CX=0");

        // TF set by POPF, then REP MOVSB with CX=1: trap at the REP, CX=0.
        begin_program();
        emit_string_setup(16'd1); emit(8'h68); emit_word(16'h0102); emit(8'h9D);
        marker = pc; emit(8'hF3); emit(8'hA4); emit(8'h43);
        run_program(1'b0);
        check(debug_gpr[15:0] == 16'hDEAD && word_at(16'h5FFA) == 16'(marker) && debug_gpr[31:16] == 16'd0 &&
              memory[16'h0500] == 8'h40, "the trap after the last iteration saves IP at the REP with CX=0");

        // REPE CMPSB ended by a mismatch: the trap follows the instruction.
        begin_program();
        emit_string_setup(16'd3); emit(8'h68); emit_word(16'h0102); emit(8'h9D);
        emit(8'hF3); emit(8'hA6); marker = pc; emit(8'h43);
        memory[16'h0500] = 8'hFF;
        run_program(1'b0);
        check(debug_gpr[15:0] == 16'hDEAD && word_at(16'h5FFA) == 16'(marker) && debug_gpr[31:16] == 16'd2,
              "a compare that ends the repeat traps after the instruction");

        // LIDT with base 9000h: INT 3 reads the relocated table.
        begin_program();
        emit(8'h0F); emit(8'h01); emit(8'h1E); emit_word(16'h0200);  // LIDT [0200]
        emit(8'hCC);
        put_word(32'h0200, 16'h03FF); put_word(32'h0202, 16'h9000); put_word(32'h0204, 16'h0000);
        run_program(1'b0);
        check(debug_gpr[15:0] == 16'h1234, "a real-mode interrupt reads its vector at the IDTR base");

        $display("REAL_EVENT_ORDER PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
