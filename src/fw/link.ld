ENTRY(_start)

MEMORY {
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
    SRAM (rw) : ORIGIN = 0x00010000, LENGTH = 256
}

SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > ROM

    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
}
