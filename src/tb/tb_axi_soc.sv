`timescale 1ns / 1ps

module tb_axi_soc;
    localparam time CLK_PERIOD = 20ns;
    localparam time UART_BIT = 8680ns; // 434 clocks at 50 MHz
    localparam logic [31:0] SRAM_BASE = 32'h0001_0000;
    localparam logic [31:0] UART_TX = 32'h1000_0000;
    localparam logic [31:0] UART_RX = 32'h1000_0004;
    localparam logic [31:0] UART_STATUS = 32'h1000_0008;
    localparam byte ECHO_BYTE = 8'hA5;
    localparam string SRAM_REPORT = "SRAM PASS (64 words, byte and halfword access)\n";
    localparam string UART_READY_REPORT = "UART READY (send 3 bytes)\n";
    localparam string UART_DONE_REPORT = "UART ECHO COMPLETE\n";

    logic clk = 0;
    logic reset = 1;
    logic uart_rx = 1;
    wire uart_tx;
    top dut (.clk(clk), .reset(reset), .uart_rx(uart_rx), .uart_tx(uart_tx));
    always #(CLK_PERIOD / 2) clk = ~clk;

    initial begin : wave_dump
        string wave_path;
        if ($value$plusargs("waves=%s", wave_path)) begin
            $display("[waves] %s", wave_path);
            $dumpfile(wave_path);
            $dumpvars(0, tb_axi_soc);
        end
    end

    bit sram_test, firmware_test;
    logic [31:0] reset_instruction;
    logic [31:0] expected_rom [0:2047];
    logic [31:0] expected_sram [0:63];
    bit [63:0] sram_words_written, sram_words_read;
    bit [15:0] sram_strobes;
    byte axi_uart_bytes[$];
    int fetches, sram_writes, sram_reads, uart_writes, rx_reads;
    int aw_stalls, w_stalls;
    bit rx_status_seen, rx_byte_pending;
    byte expected_rx_byte;

    bit aw_seen, w_seen, ar_seen;
    logic [2:0] write_slave, read_slave;
    logic [31:0] read_addr;
    bit read_is_fetch;
    bit completion_pending, completion_is_read;
    logic [31:0] completion_data;

    function automatic logic [2:0] target(input logic [31:0] addr);
        if (addr < 32'h0000_2000) return 3'b001;
        if (addr >= SRAM_BASE && addr < SRAM_BASE + 256) return 3'b010;
        if (addr >= UART_TX && addr < UART_TX + 16) return 3'b100;
        return 3'b000;
    endfunction

    task automatic record_sram_write(input logic [31:0] addr,
                                      input logic [31:0] data, input logic [3:0] strb);
        logic [5:0] word_index;
        if (!(sram_test || firmware_test) || addr[1:0] !== 2'b00)
            $fatal(1, "Unexpected SRAM write at %08h", addr);
        if (sram_test) begin
            if (addr !== SRAM_BASE) $fatal(1, "Unexpected SRAM smoke-test address %08h", addr);
            case (sram_writes)
                0: if ({strb, data} !== 36'hf_1122_3344) $fatal(1, "Bad SRAM word write");
                1: if (strb !== 4'b0010 || data[15:8] !== 8'h5a) $fatal(1, "Bad SRAM byte write");
                default: $fatal(1, "Extra SRAM smoke-test write");
            endcase
        end
        word_index = addr[7:2];
        for (int lane = 0; lane < 4; lane++) begin
            if (strb[lane]) expected_sram[word_index][8 * lane +: 8] = data[8 * lane +: 8];
        end
        if (strb == 4'hf) sram_words_written[word_index] = 1;
        sram_strobes[strb] = 1;
        sram_writes++;
    endtask

    task automatic check_sram_read(input logic [31:0] addr, input logic [31:0] data);
        logic [5:0] word_index;
        word_index = addr[7:2];
        if (!sram_words_written[word_index] || data !== expected_sram[word_index])
            $fatal(1, "Bad SRAM read at %08h: expected %08h, got %08h",
                   addr, expected_sram[word_index], data);
        if (sram_test && (addr !== SRAM_BASE || sram_reads >= 3 ||
            sram_writes != (sram_reads == 0 ? 1 : 2)))
            $fatal(1, "Unexpected SRAM smoke-test read %0d at %08h", sram_reads, addr);
        sram_words_read[word_index] = 1;
        sram_reads++;
    endtask

    // Each source must keep VALID and its payload stable until READY.
    aw_stable: assert property (@(posedge clk) disable iff (reset)
        dut.m_axi_awvalid && !dut.m_axi_awready |=>
        dut.m_axi_awvalid && $stable(dut.m_axi_awaddr)) else $fatal(1, "AW changed while stalled");
    w_stable: assert property (@(posedge clk) disable iff (reset)
        dut.m_axi_wvalid && !dut.m_axi_wready |=> dut.m_axi_wvalid &&
        $stable({dut.m_axi_wdata, dut.m_axi_wstrb_r})) else $fatal(1, "W changed while stalled");
    b_stable: assert property (@(posedge clk) disable iff (reset)
        dut.m_axi_bvalid && !dut.m_axi_bready |=>
        dut.m_axi_bvalid && $stable(dut.m_axi_bresp)) else $fatal(1, "B changed while stalled");
    ar_stable: assert property (@(posedge clk) disable iff (reset)
        dut.m_axi_arvalid && !dut.m_axi_arready |=>
        dut.m_axi_arvalid && $stable(dut.m_axi_araddr)) else $fatal(1, "AR changed while stalled");
    r_stable: assert property (@(posedge clk) disable iff (reset)
        dut.m_axi_rvalid && !dut.m_axi_rready |=> dut.m_axi_rvalid &&
        $stable({dut.m_axi_rdata, dut.m_axi_rresp})) else $fatal(1, "R changed while stalled");

    wire [2:0] aw_valid = {dut.s2_awvalid, dut.s1_awvalid, dut.s0_awvalid};
    wire [2:0] aw_ready = {dut.s2_awready, dut.s1_awready, dut.s0_awready};
    wire [2:0] w_valid = {dut.s2_wvalid, dut.s1_wvalid, dut.s0_wvalid};
    wire [2:0] w_ready = {dut.s2_wready, dut.s1_wready, dut.s0_wready};
    wire [2:0] ar_valid = {dut.s2_arvalid, dut.s1_arvalid, dut.s0_arvalid};
    wire [2:0] ar_ready = {dut.s2_arready, dut.s1_arready, dut.s0_arready};
    wire [2:0] b_transfer = {dut.s2_bvalid && dut.s2_bready,
                              dut.s1_bvalid && dut.s1_bready,
                              dut.s0_bvalid && dut.s0_bready};
    wire [2:0] r_transfer = {dut.s2_rvalid && dut.s2_rready,
                              dut.s1_rvalid && dut.s1_rready,
                              dut.s0_rvalid && dut.s0_rready};

    // Sample the same edge as the DUT. The scoreboard models one CPU request
    // at a time and tracks AW and W independently.
    always @(posedge clk) begin : bus_monitor
        logic [2:0] aw_target, w_target, ar_target;
        if (!reset) begin
            if (dut.u_cpu.trap) $fatal(1, "CPU trapped at address %08h", dut.cpu_mem_addr);
            if (dut.cpu_mem_ready !== completion_pending)
                $fatal(1, "CPU ready did not match the previous AXI response");
            if (completion_pending && (!dut.cpu_mem_valid ||
                (completion_is_read && dut.cpu_mem_rdata !== completion_data)))
                $fatal(1, "Invalid CPU completion at %08h", dut.cpu_mem_addr);
            completion_pending = 0;

            aw_target = dut.m_axi_awvalid ? target(dut.m_axi_awaddr) : 3'b000;
            ar_target = dut.m_axi_arvalid ? target(dut.m_axi_araddr) : 3'b000;
            w_target = dut.m_axi_wvalid ? (aw_seen ? write_slave : aw_target) : 3'b000;
            if (aw_valid !== aw_target || w_valid !== w_target || ar_valid !== ar_target)
                $fatal(1, "Wrong slave selection on AW, W, or AR");
            if ((dut.m_axi_awvalid && aw_target == 0) ||
                (dut.m_axi_arvalid && ar_target == 0) || (dut.m_axi_wvalid && w_target == 0))
                $fatal(1, "Unexpected address outside the tested memory map");
            if ((|(aw_valid & aw_ready)) !== (dut.m_axi_awvalid && dut.m_axi_awready) ||
                (|(w_valid & w_ready)) !== (dut.m_axi_wvalid && dut.m_axi_wready) ||
                (|(ar_valid & ar_ready)) !== (dut.m_axi_arvalid && dut.m_axi_arready))
                $fatal(1, "Request handshake did not propagate through the interconnect");

            if (dut.m_axi_awvalid && !dut.m_axi_awready) aw_stalls++;
            if (dut.m_axi_wvalid && !dut.m_axi_wready) w_stalls++;

            if (dut.m_axi_awvalid && dut.m_axi_awready) begin
                if (aw_seen || ar_seen || !dut.cpu_mem_valid || dut.cpu_mem_instr ||
                    dut.cpu_mem_wstrb == 0 || dut.m_axi_awaddr !== dut.cpu_mem_addr)
                    $fatal(1, "Unexpected AW transfer at %08h", dut.m_axi_awaddr);
                aw_seen = 1;
                write_slave = aw_target;
            end
            if (dut.m_axi_wvalid && dut.m_axi_wready) begin
                if (w_seen || ar_seen || !dut.cpu_mem_valid || dut.cpu_mem_wstrb == 0 ||
                    {dut.m_axi_wdata, dut.m_axi_wstrb_r} !== {dut.cpu_mem_wdata, dut.cpu_mem_wstrb})
                    $fatal(1, "Unexpected W transfer at %08h", dut.cpu_mem_addr);
                w_seen = 1;
                case (w_target)
                    3'b010: record_sram_write(dut.cpu_mem_addr, dut.s1_wdata, dut.s1_wstrb);
                    3'b100: begin
                        if (dut.cpu_mem_addr !== UART_TX || dut.s2_wstrb !== 4'b0001 ||
                            dut.s2_wdata[7:0] !== dut.cpu_mem_wdata[7:0])
                            $fatal(1, "Bad UART TX bus write");
                        axi_uart_bytes.push_back(dut.s2_wdata[7:0]);
                        uart_writes++;
                    end
                    default: $fatal(1, "Unexpected ROM write");
                endcase
            end
            if (dut.m_axi_arvalid && dut.m_axi_arready) begin
                if (ar_seen || aw_seen || w_seen || !dut.cpu_mem_valid ||
                    dut.cpu_mem_wstrb != 0 || dut.m_axi_araddr !== dut.cpu_mem_addr)
                    $fatal(1, "Unexpected AR transfer at %08h", dut.m_axi_araddr);
                ar_seen = 1;
                read_slave = ar_target;
                read_addr = dut.m_axi_araddr;
                read_is_fetch = dut.cpu_mem_instr;
                if (read_is_fetch && read_slave !== 3'b001)
                    $fatal(1, "Instruction fetch outside ROM at %08h", read_addr);
            end

            if (dut.m_axi_bvalid && dut.m_axi_bready) begin
                if (!aw_seen || !w_seen || b_transfer !== write_slave || dut.m_axi_bresp !== 2'b00)
                    $fatal(1, "Unexpected write response");
                aw_seen = 0;
                w_seen = 0;
                completion_pending = 1;
                completion_is_read = 0;
            end else if (b_transfer != 0) $fatal(1, "Slave B transfer without master handshake");

            if (dut.m_axi_rvalid && dut.m_axi_rready) begin
                if (!ar_seen || completion_pending || r_transfer !== read_slave || dut.m_axi_rresp !== 2'b00)
                    $fatal(1, "Unexpected read response");
                case (read_slave)
                    3'b001: begin
                        if (dut.m_axi_rdata !== expected_rom[read_addr[12:2]])
                            $fatal(1, "Wrong ROM data at %08h: %08h", read_addr, dut.m_axi_rdata);
                        if (read_is_fetch) begin
                            if (fetches == 0 && (read_addr !== 32'h0 || dut.m_axi_rdata !== reset_instruction))
                                $fatal(1, "Incorrect reset-vector fetch");
                            fetches++;
                        end
                    end
                    3'b010: check_sram_read(read_addr, dut.m_axi_rdata);
                    3'b100: begin
                        case (read_addr)
                            UART_STATUS: if (dut.m_axi_rdata[1]) rx_status_seen = 1;
                            UART_RX: begin
                                if (!rx_byte_pending || !rx_status_seen ||
                                    dut.m_axi_rdata[8:0] !== {1'b1, expected_rx_byte})
                                    $fatal(1, "Incorrect UART RX register data: %08h", dut.m_axi_rdata);
                                rx_byte_pending = 0;
                                rx_reads++;
                            end
                            default: $fatal(1, "Unexpected UART read at %08h", read_addr);
                        endcase
                    end
                    default: $fatal(1, "Read response from unknown device");
                endcase
                ar_seen = 0;
                completion_pending = 1;
                completion_is_read = 1;
                completion_data = dut.m_axi_rdata;
            end else if (r_transfer != 0) $fatal(1, "Slave R transfer without master handshake");
        end
    end

    task automatic receive_uart(output byte serial_byte);
        byte bus_byte;
        @(negedge uart_tx);
        #(UART_BIT / 2);
        if (uart_tx !== 1'b0) $fatal(1, "Invalid UART start bit");
        for (int i = 0; i < 8; i++) begin
            #UART_BIT;
            serial_byte[i] = uart_tx;
        end
        #UART_BIT;
        if (uart_tx !== 1'b1) $fatal(1, "Invalid UART stop bit");
        if (axi_uart_bytes.size() == 0) $fatal(1, "UART frame without a preceding AXI write");
        bus_byte = axi_uart_bytes.pop_front();
        if (serial_byte !== bus_byte)
            $fatal(1, "UART byte mismatch: AXI %02h, serial %02h", bus_byte, serial_byte);
    endtask

    task automatic expect_uart(input byte expected);
        byte received;
        receive_uart(received);
        if (received !== expected)
            $fatal(1, "UART byte mismatch: expected %02h, serial %02h", expected, received);
    endtask

    task automatic expect_uart_line(input string expected);
        string received = "";
        byte value;
        for (int i = 0; i < expected.len(); i++) begin
            receive_uart(value);
            received = {received, string'(value)};
            if (value == "\n") break;
        end
        if (received != expected)
            $fatal(1, "UART report mismatch: expected %s, received %s", expected, received);
        $write("[firmware] %s", received);
    endtask

    task automatic send_uart(input byte value);
        uart_rx = 0;
        #UART_BIT;
        for (int i = 0; i < 8; i++) begin
            uart_rx = value[i];
            #UART_BIT;
        end
        uart_rx = 1;
        #UART_BIT;
    endtask

    task automatic expect_echo(input byte value);
        expected_rx_byte = value;
        rx_byte_pending = 1;
        rx_status_seen = 0;
        fork
            send_uart(value);
            expect_uart(value);
        join
        if (rx_byte_pending) $fatal(1, "Echo completed without a UART RX register read");
        if (firmware_test) $display("[testbench] UART echo PASS for 0x%02h", value);
    endtask

    initial begin : test_sequence
        string rom_path, greeting, scenario;
        sram_test = $test$plusargs("sram_test");
        firmware_test = $test$plusargs("firmware_test");
        if (sram_test && firmware_test) $fatal(1, "Choose one test scenario");
        if (firmware_test) reset_instruction = 32'h0001_0437;
        else if (sram_test) reset_instruction = 32'h0001_02b7;
        else reset_instruction = 32'h0002_0137;
        if (!$value$plusargs("romhex=%s", rom_path)) rom_path = "rom.hex";
        foreach (expected_rom[i]) expected_rom[i] = 32'h0000_0013;
        $readmemh(rom_path, expected_rom);

        repeat (5) @(negedge clk);
        reset = 0;

        if (firmware_test) begin
            scenario = "firmware";
            expect_uart_line(SRAM_REPORT);
            expect_uart_line(UART_READY_REPORT);
            expect_echo(8'h00);
            expect_echo(8'h80);
            expect_echo(8'hff);
            expect_uart_line(UART_DONE_REPORT);
            // Require all 64 words and the f/1/2/4/8/3/c write strobes.
            if (!(&sram_words_written) || !(&sram_words_read) || sram_strobes !== 16'h911e ||
                sram_writes < 70 || sram_reads < 70 || rx_reads != 3 ||
                uart_writes != SRAM_REPORT.len() + UART_READY_REPORT.len() + UART_DONE_REPORT.len() + 3)
                $fatal(1, "Firmware scenario missed expected SRAM or UART transactions");
        end else if (sram_test) begin
            scenario = "SRAM";
            expect_uart("Z");
            if (sram_writes != 2 || sram_reads != 3 || uart_writes != 1)
                $fatal(1, "SRAM scenario did not complete all expected transactions");
        end else begin
            scenario = "boot/echo";
            greeting = "Hello Deepak from Nielit!\n";
            repeat (10) begin
                for (int i = 0; i < greeting.len(); i++) expect_uart(greeting[i]);
            end
            expect_echo(ECHO_BYTE);
            if (rx_reads != 1 || uart_writes != 10 * greeting.len() + 1 ||
                aw_stalls == 0 || w_stalls == 0)
                $fatal(1, "Boot scenario did not cover UART RX, TX, and write backpressure");
        end

        if (fetches < 2 || axi_uart_bytes.size() != 0)
            $fatal(1, "Missing instruction fetches or undelivered UART writes");
        $display("PASS %s: fetch=%0d SRAM writes=%0d reads=%0d UART TX=%0d RX=%0d AW/W stall cycles=%0d/%0d",
                 scenario, fetches, sram_writes, sram_reads,
                 uart_writes, rx_reads, aw_stalls, w_stalls);
        $finish;
    end

    initial begin
        #30ms;
        $fatal(1, "Test timeout: fetch=%0d SRAM writes=%0d reads=%0d UART writes=%0d",
               fetches, sram_writes, sram_reads, uart_writes);
    end
endmodule
