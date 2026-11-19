    .section .text.start,"ax",@progbits
    .globl _start
_start:
    li s0, 0x00010000            # SRAM base
    li s2, 0x5aa58000            # Starting word pattern
    addi s3, s0, 256             # End of SRAM

    # Fill every word before reading any of them. Each address gets a
    # different value so an address alias cannot pass the readback loop.
    mv t0, s0
    mv t1, s2
fill_sram:
    sw t1, 0(t0)
    addi t0, t0, 4
    addi t1, t1, 1
    bne t0, s3, fill_sram

    mv t0, s0
    mv t1, s2
check_sram:
    lw t2, 0(t0)
    bne t2, t1, fail
    addi t0, t0, 4
    addi t1, t1, 1
    bne t0, s3, check_sram

    li t0, 0x80
    sb t0, 0(s0)
    li t0, 0x7e
    sb t0, 1(s0)
    li t0, 0xb6
    sb t0, 2(s0)
    li t0, 0xf1
    sb t0, 3(s0)
    lw t0, 0(s0)
    li t1, 0xf1b67e80
    bne t0, t1, fail

    lb t0, 0(s0)
    li t1, -128
    bne t0, t1, fail
    lbu t0, 0(s0)
    li t1, 0x80
    bne t0, t1, fail
    lh t0, 2(s0)
    li t1, 0xfffff1b6
    bne t0, t1, fail
    lhu t0, 2(s0)
    li t1, 0xf1b6
    bne t0, t1, fail

    li t0, 0x1234
    sh t0, -4(s3)                # Low halfword of the last SRAM word
    li t0, 0x89ab
    sh t0, -2(s3)                # High halfword of the last SRAM word
    lw t0, -4(s3)
    li t1, 0x89ab1234
    bne t0, t1, fail

    li a0, 1
    j start_main

fail:
    li a0, 0

start_main:
    # Start using the stack after testing the entire SRAM without one.
    la sp, _stack_top
    tail main
