CROSS ?= riscv64-unknown-elf
BUILD_DIR ?= build
PYTHON ?= python3

CC = $(CROSS)-gcc
OBJCOPY = $(CROSS)-objcopy
OBJDUMP = $(CROSS)-objdump

ARCH_FLAGS := -march=rv32i -mabi=ilp32 -mno-relax -msmall-data-limit=0
CFLAGS ?= -O2 -Wall -Wextra
SOURCES := crt0.S main.c
ROM_DEPTH := 2048
ELF := $(BUILD_DIR)/firmware.elf
BIN := $(BUILD_DIR)/firmware.bin
HEX := $(BUILD_DIR)/firmware.hex
ROM_CASE := $(BUILD_DIR)/firmware_rom_case.vh

.PHONY: all disassemble clean
.DELETE_ON_ERROR:

all: $(HEX) $(ROM_CASE)

$(ELF): $(SOURCES) link.ld Makefile
	mkdir -p "$(@D)"
	$(CC) $(ARCH_FLAGS) $(CFLAGS) -ffreestanding -nostdlib -T link.ld -o "$@" $(SOURCES)

$(BIN): $(ELF)
	$(OBJCOPY) -j .text -O binary "$<" "$@"

$(HEX): $(BIN) bin2hex.py Makefile
	$(PYTHON) bin2hex.py "$<" "$@" --depth $(ROM_DEPTH)

$(ROM_CASE): $(HEX) gen_rom_case.py Makefile
	$(PYTHON) gen_rom_case.py "$<" $(ROM_DEPTH) -o "$@"

disassemble: $(ELF)
	$(OBJDUMP) -d "$<"

clean:
	rm -f -- "$(ELF)" "$(BIN)" "$(HEX)" "$(ROM_CASE)"
