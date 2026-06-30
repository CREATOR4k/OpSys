; ============================================================
;  Минимальный загрузчик: 16-bit real mode -> 32-bit protected
;  -> 64-bit long mode. Печатает текст в обоих режимах.
;  Собирается в плоский бинарник boot.bin (512 байт, boot sector).
; ============================================================

BITS 16
ORG 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov si, msg_real_mode
    call print_string_16

    call enable_a20
    cli

    lgdt [gdt_descriptor]

    mov eax, cr0
    or  eax, 1
    mov cr0, eax

    jmp CODE_SEG32:protected_mode_entry

; ------------------------------------------------------------
; печать строки в реальном режиме через BIOS int 0x10 (teletype)
; SI -> указатель на ASCIIZ строку
; ------------------------------------------------------------
print_string_16:
    pusha
    mov ah, 0x0E
.next:
    lodsb
    cmp al, 0
    je  .done
    int 0x10
    jmp .next
.done:
    popa
    ret

; ------------------------------------------------------------
; включение линии A20 через порт 0x92 (быстрый метод)
; ------------------------------------------------------------
enable_a20:
    in   al, 0x92
    test al, 2
    jnz  .done
    or   al, 2
    and  al, 0xFE
    out  0x92, al
.done:
    ret

; ============================================================
; GDT: нужен дескриптор для 32-бит кода/данных и для 64-бит
; кода (long mode), чтобы потом прыгнуть в него.
; ============================================================
gdt_start:
    dq 0x0000000000000000          ; null descriptor

gdt_code32:
    dw 0xFFFF                      ; limit low
    dw 0x0000                      ; base low
    db 0x00                        ; base middle
    db 10011010b                   ; access: present, ring0, code, exec/read
    db 11001111b                   ; flags + limit high (4K gran, 32-bit)
    db 0x00                        ; base high

gdt_data32:
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b                   ; access: present, ring0, data, read/write
    db 11001111b
    db 0x00

gdt_code64:
    dw 0x0000                      ; limit ignored in long mode
    dw 0x0000
    db 0x00
    db 10011010b                   ; present, ring0, code, exec/read
    db 00100000b                   ; L-bit=1 (64-bit code), D=0
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG32 equ gdt_code32 - gdt_start
DATA_SEG32 equ gdt_data32 - gdt_start
CODE_SEG64 equ gdt_code64 - gdt_start

; ============================================================
; 32-бит защищённый режим
; ============================================================
BITS 32
protected_mode_entry:
    mov ax, DATA_SEG32
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    mov esi, msg_protected_mode
    call print_string_32

    call setup_paging
    call enter_long_mode

    jmp CODE_SEG64:long_mode_entry

; ------------------------------------------------------------
; печать строки в 32-битном режиме напрямую в видеопамять
; ESI -> ASCIIZ строка. Цвет: светло-зелёный на чёрном (0x0A).
; ------------------------------------------------------------
VIDEO_MEM equ 0xB8000

print_string_32:
    pusha
    mov edi, VIDEO_MEM
.next:
    mov al, [esi]
    cmp al, 0
    je  .done
    mov ah, 0x0A
    mov [edi], ax
    add edi, 2
    inc esi
    jmp .next
.done:
    popa
    ret

; ------------------------------------------------------------
; настройка таблиц страниц для identity-mapping первых 2 MB
; PML4 -> PDPT -> PD (используем страницы по 2MB, без PT)
; Таблицы кладём по фиксированным адресам в низкой памяти.
; ------------------------------------------------------------
PML4_ADDR equ 0x1000
PDPT_ADDR equ 0x2000
PD_ADDR   equ 0x3000

setup_paging:
    ; очистка области под таблицы (3 страницы по 4KB)
    mov edi, PML4_ADDR
    mov ecx, 3 * 4096 / 4
    xor eax, eax
    rep stosd

    ; PML4[0] -> PDPT
    mov eax, PDPT_ADDR
    or  eax, 0b11           ; present + writable
    mov [PML4_ADDR], eax

    ; PDPT[0] -> PD
    mov eax, PD_ADDR
    or  eax, 0b11
    mov [PDPT_ADDR], eax

    ; PD: 4 записи по 2MB-страницы = identity map первых 8 MB
    mov edi, PD_ADDR
    mov eax, 0b10000011     ; present + writable + page size (2MB)
    mov ecx, 4
.fill_pd:
    mov [edi], eax
    add eax, 0x200000
    add edi, 8
    loop .fill_pd

    ret

; ------------------------------------------------------------
; переключение в long mode: PAE, CR3, EFER.LME, paging (CR0.PG)
; ------------------------------------------------------------
enter_long_mode:
    mov eax, PML4_ADDR
    mov cr3, eax

    mov eax, cr4
    or  eax, 1 << 5          ; PAE
    mov cr4, eax

    mov ecx, 0xC0000080      ; EFER MSR
    rdmsr
    or  eax, 1 << 8          ; LME
    wrmsr

    mov eax, cr0
    or  eax, 1 << 31         ; PG
    mov cr0, eax

    ret

; ============================================================
; 64-бит long mode
; ============================================================
BITS 64
long_mode_entry:
    mov ax, DATA_SEG32        ; используем тот же flat-дескриптор данных
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, 0x90000

    mov rsi, msg_long_mode
    call print_string_64

.hang:
    hlt
    jmp .hang

; ------------------------------------------------------------
; печать строки в 64-битном режиме (видеопамять, цвет жёлтый)
; RSI -> ASCIIZ строка
; ------------------------------------------------------------
print_string_64:
    push rax
    push rdi
    mov rdi, VIDEO_MEM + 160     ; следующая строка экрана (80*2 байт)
.next:
    mov al, [rsi]
    cmp al, 0
    je  .done
    mov ah, 0x0E
    mov [rdi], ax
    add rdi, 2
    inc rsi
    jmp .next
.done:
    pop rdi
    pop rax
    ret

; ============================================================
; данные
; ============================================================
BITS 16
msg_real_mode:      db "Real mode: hello!", 13, 10, 0
msg_protected_mode:  db "Protected mode (32-bit): hello!", 0
msg_long_mode:       db "Long mode (64-bit): hello, world!", 0

; ============================================================
; заполнение до 510 байт + сигнатура загрузочного сектора
; ============================================================
times 510 - ($ - $$) db 0
dw 0xAA55