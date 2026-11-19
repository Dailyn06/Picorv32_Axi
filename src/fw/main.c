typedef unsigned char uint8_t;
typedef unsigned int uint32_t;

#define UART_TX     (*(volatile uint8_t  *)0x10000000u)
#define UART_RX     (*(volatile uint8_t  *)0x10000004u)
#define UART_STATUS (*(volatile uint32_t *)0x10000008u)
#define RX_VALID    (1u << 1)

static void uart_puts(const char *text)
{
    while (*text) {
        UART_TX = (uint8_t)*text++;
    }
}

void main(unsigned memory_ok)
{
    if (memory_ok) {
        uart_puts("SRAM PASS (64 words, byte and halfword access)\n");
        uart_puts("UART READY (send 3 bytes)\n");

        for (unsigned remaining = 3; remaining != 0; --remaining) {
            while ((UART_STATUS & RX_VALID) == 0) {
            }
            uint8_t received = UART_RX;
            UART_TX = received;
        }

        uart_puts("UART ECHO COMPLETE\n");
    } else {
        uart_puts("SRAM FAIL\n");
    }

    for (;;) {
    }
}
