/* The run checks of the C/C++ library packages (tools/checks/*.sh): one image in
   the 4 MiB SSRAM at 0 of qemu's mps2-an385/an386, writable, so crt0 has no
   .data to copy. The vector table is the test program's; the stack is the top
   of the RAM (__stack, which crt0 takes). */
MEMORY { RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 4M }
ENTRY(_start)
SECTIONS
{
    .text : {
        KEEP(*(.vectors))
        *(.text .text.*)
        KEEP(*(.init)) KEEP(*(.fini))
        *(.rodata .rodata.*)
    } > RAM
    .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } > RAM
    .ARM.exidx : { __exidx_start = .; *(.ARM.exidx*) __exidx_end = .; } > RAM
    .preinit_array : {
        PROVIDE_HIDDEN(__preinit_array_start = .); KEEP(*(.preinit_array)) PROVIDE_HIDDEN(__preinit_array_end = .);
    } > RAM
    .init_array : {
        PROVIDE_HIDDEN(__init_array_start = .); KEEP(*(SORT(.init_array.*))) KEEP(*(.init_array)) PROVIDE_HIDDEN(__init_array_end = .);
    } > RAM
    .fini_array : {
        PROVIDE_HIDDEN(__fini_array_start = .); KEEP(*(SORT(.fini_array.*))) KEEP(*(.fini_array)) PROVIDE_HIDDEN(__fini_array_end = .);
    } > RAM
    .data : { *(.data .data.*) } > RAM
    .bss : { __bss_start__ = .; *(.bss .bss.*) *(COMMON) . = ALIGN(4); __bss_end__ = .; } > RAM
    end = .; PROVIDE(_end = .); PROVIDE(__end__ = .);   /* the heap starts here (rdimon: __end__) */
    __stack = ORIGIN(RAM) + LENGTH(RAM);
}
