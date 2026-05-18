; ==============================================================================
; WSAPatch - io.asm
; Console output helpers (WriteFile to stdout, no CRT)
;
; Exports:
;   OutStr  RCX=LPCSTR
;   OutHex  RCX=DWORD   (hex, no leading zeros, no "0x" prefix)
;   OutByte RCX=BYTE    (always two hex chars: "EB", "90")
; ==============================================================================

option casemap:none

include consts.inc

EXTRN WriteFile:PROC
EXTRN g_stdout:QWORD

.code

; ==============================================================================
; OutStr - Write null-terminated ANSI string to stdout
;
; Stack frame: 2 non-volatile pushes (rbx, rsi) + sub rsp,56
;   Entry RSP%16=8. After 2 pushes: RSP%16=8. 56%16=8 -> aligned to 16 before CALL.
;   [rsp+0..31]  shadow space for WriteFile
;   [rsp+32..39] 5th param (lpOverlapped=NULL)
;   [rsp+40..43] bytesWritten DWORD  (R9 = rsp+40)
;   [rsp+44..55] unused
; ==============================================================================
OutStr proc
    push rbx
    push rsi
    sub rsp, 56

    test rcx, rcx
    jz outstr_ret

    mov rbx, rcx                    ; rbx = string base

    ; compute length
    xor eax, eax
outstr_len:
    cmp byte ptr [rbx+rax], 0
    je  outstr_write
    inc eax
    jmp outstr_len

outstr_write:
    test eax, eax
    jz  outstr_ret

    mov qword ptr [rsp+32], 0       ; lpOverlapped = NULL (5th param)
    mov dword ptr [rsp+40], 0       ; bytesWritten = 0
    lea r9,  [rsp+40]               ; &bytesWritten
    mov r8d, eax                    ; nNumberOfBytesToWrite
    mov rdx, rbx                    ; lpBuffer
    mov rcx, qword ptr [g_stdout]
    call WriteFile

outstr_ret:
    add rsp, 56
    pop rsi
    pop rbx
    ret
OutStr endp

; ==============================================================================
; OutHex - Print DWORD as hex, no leading zeros (minimum 1 digit)
;
; RCX = DWORD value
; Uses OutStr internally.
; ==============================================================================
OutHex proc
    push rbx
    push rsi
    sub rsp, 56                     ; same alignment as OutStr

    mov ebx, ecx                    ; save value

    ; Build 8-char hex string in [rsp+40..49], null-terminated at [rsp+49]
    lea rsi, [rsp+40]
    mov byte ptr [rsp+48], 0        ; null terminator

    ; Fill 8 hex chars (most significant first)
    mov ecx, 7
outHex_fill:
    mov eax, ebx
    and eax, 0Fh
    cmp al, 10
    jae outHex_alpha
    add al, '0'
    jmp outHex_store
outHex_alpha:
    add al, 'A' - 10
outHex_store:
    mov byte ptr [rsi+rcx], al
    shr ebx, 4
    dec ecx
    jge outHex_fill

    ; Skip leading zeros (keep at least 1 digit)
    mov rcx, rsi                    ; point to first char
outHex_skip:
    cmp byte ptr [rcx+1], 0         ; if next is null, stop
    je  outHex_print
    cmp byte ptr [rcx], '0'
    jne outHex_print
    inc rcx
    jmp outHex_skip

outHex_print:
    call OutStr

    add rsp, 56
    pop rsi
    pop rbx
    ret
OutHex endp

; ==============================================================================
; OutByte - Print single byte as two uppercase hex chars (e.g. 0EB -> "EB")
;
; RCX = byte value (only low 8 bits used)
; ==============================================================================
OutByte proc
    push rbx
    push rsi
    sub rsp, 56

    mov ebx, ecx
    and ebx, 0FFh

    ; Build "XY\0" at [rsp+40]
    lea rsi, [rsp+40]

    ; High nibble
    mov eax, ebx
    shr eax, 4
    cmp al, 10
    jae outByte_hiAlpha
    add al, '0'
    jmp outByte_hiStore
outByte_hiAlpha:
    add al, 'A' - 10
outByte_hiStore:
    mov byte ptr [rsi], al

    ; Low nibble
    mov eax, ebx
    and eax, 0Fh
    cmp al, 10
    jae outByte_loAlpha
    add al, '0'
    jmp outByte_loStore
outByte_loAlpha:
    add al, 'A' - 10
outByte_loStore:
    mov byte ptr [rsi+1], al

    mov byte ptr [rsi+2], 0

    mov rcx, rsi
    call OutStr

    add rsp, 56
    pop rsi
    pop rbx
    ret
OutByte endp

END
