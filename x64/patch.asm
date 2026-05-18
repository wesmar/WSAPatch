; ==============================================================================
; WSAPatch - patch.asm
; Entry point, patch table, orchestration
;
; Author: Marek Wesołowski (wesmar)
; Purpose: Patches WsaClient.exe (WSABuilds 2407.40000.4.0) to bypass
;          AppUriHandlerRegistrationManager.UpdateAsync() E_ACCESSDENIED crash
;          on Windows 11 26H1 (build 28000+).
; ==============================================================================

option casemap:none

include consts.inc

; --- io.asm ---
EXTRN OutStr:PROC
EXTRN OutHex:PROC
EXTRN OutByte:PROC

; --- scan.asm ---
EXTRN ScanPatch:PROC

; --- reg.asm ---
EXTRN FindWsaPath:PROC
EXTRN StrCatA:PROC

; --- Win32 ---
EXTRN GetStdHandle:PROC
EXTRN GetCommandLineA:PROC
EXTRN GetProcessHeap:PROC
EXTRN HeapAlloc:PROC
EXTRN HeapFree:PROC
EXTRN CreateFileA:PROC
EXTRN GetFileSize:PROC
EXTRN ReadFile:PROC
EXTRN WriteFile:PROC
EXTRN CopyFileA:PROC
EXTRN CloseHandle:PROC
EXTRN ExitProcess:PROC

; ==============================================================================
; .const - strings and patch table
; ==============================================================================
.const

str_p1_name  db 'Bypass E_ACCESSDENIED check (JNE->JMP)',0
str_p2_name  db 'Ignore HRESULT from GetResults() (JS->NOP NOP)',0

str_banner1  db 'WsaClient.exe patcher for Windows 11 26H1',13,10,0
str_banner2  db '==========================================',13,10,0
str_no_arg   db '[*] No path given - searching via WsaService registry...',13,10,0
str_target   db '[*] Target: ',0
str_via_reg  db '[*] Path found via registry',13,10,0
str_read_ok  db '[*] Read 0x',0
str_bytes    db ' bytes',13,10,0
str_crlf     db 13,10,0
str_pn       db 'Patch ',0
str_colon    db ': ',0
str_notfound db '  [!] NOT FOUND - unsupported file version',13,10,0
str_alr1     db '  [=] Already patched (offset 0x',0
str_alr2     db ')',13,10,0
str_found1   db '  [+] Found at 0x',0
str_found2   db ', patching 0x',0
str_found3   db ': ',0
str_arrow    db ' -> ',0
str_sp       db ' ',0
str_backup   db '[*] Backup saved to *.bak',13,10,0
str_done1    db '[*] Done. 1 patch applied.',13,10,0
str_done2    db '[*] Done. 2 patches applied.',13,10,0
str_alr_all  db '[=] Already fully patched. Nothing to do.',13,10,0
str_fail_ver db '[!] Patch(es) not found - unsupported version. File NOT written.',13,10,0
str_err_open db '[!] Cannot open file',13,10,0
str_err_size db '[!] GetFileSize failed',13,10,0
str_err_mem  db '[!] HeapAlloc failed',13,10,0
str_err_read db '[!] ReadFile failed',13,10,0
str_err_bak  db '[!] Backup failed - aborting',13,10,0
str_err_writ db '[!] WriteFile failed',13,10,0
str_err_path db '[!] Cannot locate WsaClient.exe. Pass path as argument.',13,10,0
str_1        db '1',0
str_2        db '2',0

; --- Patch descriptor table ---
; Layout per PATCH_DESC struct (48 bytes each)
PUBLIC patches
patches LABEL BYTE
    ; PATCH 1: CMP EBX,80070005h / JNE +19h -> JMP +19h
    dq  offset str_p1_name
    db  81h, 0FBh, 05h, 00h, 07h, 80h, 0, 0
    dd  6
    db  75h, 0, 0, 0
    db  0EBh, 0, 0, 0
    dd  1
    db  19h, 0, 0, 0, 0, 0, 0, 0
    dd  1
    dd  0

    ; PATCH 2: TEST EAX,EAX / JS +26h -> NOP NOP
    dq  offset str_p2_name
    db  85h, 0C0h, 0, 0, 0, 0, 0, 0
    dd  2
    db  78h, 26h, 0, 0
    db  90h, 90h, 0, 0
    dd  2
    db  48h, 8Bh, 4Dh, 0, 0, 0, 0, 0
    dd  3
    dd  0

; ==============================================================================
; .data - initialized globals exported to other modules
; ==============================================================================
.data
    align 8

PUBLIC g_stdout
g_stdout    dq 0

; ==============================================================================
; .data? - path buffers
; ==============================================================================
.data?

PUBLIC g_target
g_target    db 540 dup(?)       ; WsaClient.exe path (ANSI)
g_backup    db 544 dup(?)       ; g_target + ".bak"

; ==============================================================================
; .code
; ==============================================================================
.code

; ==============================================================================
; ParseArg - extract first non-program-name token from ANSI command line
; RCX=cmdLine  RDX=outBuf  R8D=outBufSize  ->  RAX=1 found / 0 none
;
; 2 pushes + sub 56 -> RSP%16=0 before calls.
; ==============================================================================
ParseArg proc
    push rbx
    push rsi
    sub  rsp, 56

    mov  rbx, rcx               ; cmdLine ptr
    mov  rsi, rdx               ; out buf
    mov  r10d, r8d              ; max

    ; skip program name (handle quotes)
    cmp  byte ptr [rbx], '"'
    jne  pa_skip_unquoted
    inc  rbx
pa_sq:
    mov  al, byte ptr [rbx]
    test al, al
    jz   pa_noarg
    inc  rbx
    cmp  al, '"'
    jne  pa_sq
    jmp  pa_ws

pa_skip_unquoted:
    mov  al, byte ptr [rbx]
    test al, al
    jz   pa_noarg
    cmp  al, ' '
    je   pa_ws
    cmp  al, 9
    je   pa_ws
    inc  rbx
    jmp  pa_skip_unquoted

pa_ws:
    mov  al, byte ptr [rbx]
    cmp  al, ' '
    je   pa_wsnext
    cmp  al, 9
    je   pa_wsnext
    jmp  pa_extract
pa_wsnext:
    inc  rbx
    jmp  pa_ws

pa_extract:
    test al, al
    jz   pa_noarg
    xor  ecx, ecx
    mov  r11b, 0
    cmp  byte ptr [rbx], '"'
    jne  pa_copy
    mov  r11b, 1
    inc  rbx

pa_copy:
    cmp  ecx, r10d
    jae  pa_done_copy
    mov  al, byte ptr [rbx]
    test al, al
    jz   pa_done_copy
    test r11b, r11b
    jz   pa_unq
    cmp  al, '"'
    je   pa_done_copy
    jmp  pa_store
pa_unq:
    cmp  al, ' '
    je   pa_done_copy
    cmp  al, 9
    je   pa_done_copy
pa_store:
    mov  byte ptr [rsi+rcx], al
    inc  rbx
    inc  ecx
    jmp  pa_copy

pa_done_copy:
    mov  byte ptr [rsi+rcx], 0
    test ecx, ecx
    jz   pa_noarg
    mov  eax, 1
    jmp  pa_ret

pa_noarg:
    xor  eax, eax
pa_ret:
    add  rsp, 56
    pop  rsi
    pop  rbx
    ret
ParseArg endp

; ==============================================================================
; ==============================================================================
; mainCRTStartup - application entry point
;
; Register map:
;   R12  = heap handle
;   R13  = file data ptr (heap buffer)
;   R14D = file size
;   R15D = patch loop index i (0..NUM_PATCHES-1)
;   RBX  = current PATCH_DESC* (recomputed each iteration)
;   RSI  = applied count
;   RDI  = failed count
;
; Stack (8 pushes -> RSP%16=8; sub 88 -> 88%16=8 -> RSP%16=0):
;   [rsp+0..31]  shadow
;   [rsp+32..39] 5th param
;   [rsp+40..47] 6th param
;   [rsp+48..55] 7th param  (CreateFileA hTemplateFile)
;   [rsp+56..63] hFile QWORD local
;   [rsp+64..67] bytesRW DWORD local
;   [rsp+68..71] state  DWORD local (scan result)
;   [rsp+72..75] already DWORD local
;   [rsp+76..79] found_off DWORD  (saved; r10 volatile across calls)
;   [rsp+80..83] patch_off DWORD  (saved; r11 volatile across calls)
;   [rsp+84..87] print index / applied count DWORD
; ==============================================================================
mainCRTStartup proc frame
    push rbp
    .pushreg rbp
    mov  rbp, rsp
    .setframe rbp, 0
    push rbx
    .pushreg rbx
    push rsi
    .pushreg rsi
    push rdi
    .pushreg rdi
    push r12
    .pushreg r12
    push r13
    .pushreg r13
    push r14
    .pushreg r14
    push r15
    .pushreg r15
    sub  rsp, 88
    .allocstack 88
    .endprolog

    ; === init stdout ===
    mov  ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov  qword ptr [g_stdout], rax

    lea  rcx, str_banner1
    call OutStr
    lea  rcx, str_banner2
    call OutStr

    ; === resolve target path ===
    call GetCommandLineA
    lea  rdx, g_target
    mov  r8d, 540
    mov  rcx, rax
    call ParseArg
    test eax, eax
    jnz  main_have_path

    lea  rcx, str_no_arg
    call OutStr
    mov  edx, 540
    lea  rcx, g_target
    call FindWsaPath
    test eax, eax
    jz   main_nopath

    lea  rcx, str_target
    call OutStr
    lea  rcx, g_target
    call OutStr
    lea  rcx, str_crlf
    call OutStr
    lea  rcx, str_via_reg
    call OutStr
    jmp  main_open_file

main_have_path:
    lea  rcx, str_target
    call OutStr
    lea  rcx, g_target
    call OutStr
    lea  rcx, str_crlf
    call OutStr

main_open_file:
    lea  rcx, str_crlf
    call OutStr

    ; === open file (read) ===
    mov  qword ptr [rsp+48], 0
    mov  dword ptr [rsp+40], FILE_ATTRIBUTE_NORMAL
    mov  dword ptr [rsp+32], OPEN_EXISTING
    xor  r9d, r9d
    mov  r8d, FILE_SHARE_READ
    mov  edx, GENERIC_READ
    lea  rcx, g_target
    call CreateFileA
    cmp  rax, INVALID_HANDLE_VALUE
    je   main_err_open
    mov  qword ptr [rsp+56], rax        ; save hFile

    ; === get size ===
    xor  edx, edx
    mov  rcx, rax
    call GetFileSize
    cmp  eax, INVALID_FILE_SIZE
    je   main_err_size
    test eax, eax
    jz   main_err_size
    mov  r14d, eax                      ; file size

    ; === alloc + read ===
    call GetProcessHeap
    mov  r12, rax
    mov  r8d, r14d
    xor  edx, edx
    mov  rcx, r12
    call HeapAlloc
    test rax, rax
    jz   main_err_mem
    mov  r13, rax

    mov  qword ptr [rsp+32], 0          ; lpOverlapped
    mov  dword ptr [rsp+64], 0
    lea  r9, [rsp+64]                   ; &bytesRead
    mov  r8d, r14d
    mov  rdx, r13
    mov  rcx, qword ptr [rsp+56]
    call ReadFile
    test eax, eax
    jz   main_err_read
    mov  eax, dword ptr [rsp+64]
    cmp  eax, r14d
    jne  main_err_read

    mov  rcx, qword ptr [rsp+56]
    call CloseHandle
    mov  qword ptr [rsp+56], 0          ; hFile closed

    lea  rcx, str_read_ok
    call OutStr
    mov  ecx, r14d
    call OutHex
    lea  rcx, str_bytes
    call OutStr
    lea  rcx, str_crlf
    call OutStr

    ; === patch loop ===
    xor  esi, esi                       ; applied = 0
    xor  edi, edi                       ; failed  = 0
    mov  dword ptr [rsp+72], 0          ; already_count = 0
    xor  r15d, r15d                     ; i = 0

main_loop:
    cmp  r15d, NUM_PATCHES
    jge  main_loop_end

    ; pDesc = patches + i * SIZEOF_PATCH_DESC
    imul rax, r15, SIZEOF_PATCH_DESC
    lea  rbx, patches
    add  rbx, rax                       ; RBX = pDesc

    ; "Patch N: name\r\n"
    lea  rcx, str_pn
    call OutStr
    test r15d, r15d
    jnz  main_pn2
    lea  rcx, str_1
    jmp  main_pn_print
main_pn2:
    lea  rcx, str_2
main_pn_print:
    call OutStr
    lea  rcx, str_colon
    call OutStr
    mov  rcx, qword ptr [rbx + PATCH_DESC.name_ptr]
    call OutStr
    lea  rcx, str_crlf
    call OutStr

    ; ScanPatch(pDesc, data, size, &state)
    mov  dword ptr [rsp+68], ST_NOT_FOUND
    lea  r9, [rsp+68]
    mov  r8d, r14d
    mov  rdx, r13
    mov  rcx, rbx
    call ScanPatch              ; RAX = found offset or -1

    mov  ecx, dword ptr [rsp+68]    ; state
    cmp  ecx, ST_NOT_FOUND
    je   main_notfound

    ; RAX = found_off, patch_off = found_off + pre_len
    mov  r10, rax
    mov  edx, dword ptr [rbx + PATCH_DESC.pre_len]
    lea  r11, [r10 + rdx]       ; r11 = patch_off
    mov  dword ptr [rsp+76], r10d  ; save found_off (r10 volatile across calls)
    mov  dword ptr [rsp+80], r11d  ; save patch_off (r11 volatile across calls)

    cmp  ecx, ST_ALREADY_PATCHED
    je   main_already

    ; === apply patch ===
    lea  rcx, str_found1
    call OutStr
    mov  ecx, dword ptr [rsp+76]   ; found_off
    call OutHex
    lea  rcx, str_found2
    call OutStr
    mov  ecx, dword ptr [rsp+80]   ; patch_off
    call OutHex
    lea  rcx, str_found3
    call OutStr

    ; print orig bytes (rbx=pDesc, non-volatile; stack index at [rsp+84])
    mov  dword ptr [rsp+84], 0
main_print_orig:
    mov  eax, dword ptr [rsp+84]
    cmp  eax, dword ptr [rbx + PATCH_DESC.patch_len]
    jge  main_print_orig_done
    movzx rcx, byte ptr [rbx + PATCH_DESC.orig_bytes + rax]
    call OutByte
    lea  rcx, str_sp
    call OutStr
    inc  dword ptr [rsp+84]
    jmp  main_print_orig
main_print_orig_done:

    lea  rcx, str_arrow
    call OutStr

    ; print repl bytes
    mov  dword ptr [rsp+84], 0
main_print_repl:
    mov  eax, dword ptr [rsp+84]
    cmp  eax, dword ptr [rbx + PATCH_DESC.patch_len]
    jge  main_print_repl_done
    movzx rcx, byte ptr [rbx + PATCH_DESC.repl_bytes + rax]
    call OutByte
    lea  rcx, str_sp
    call OutStr
    inc  dword ptr [rsp+84]
    jmp  main_print_repl
main_print_repl_done:
    lea  rcx, str_crlf
    call OutStr

    ; copy repl_bytes -> data[patch_off] using rax/r11 (leave RSI/RDI intact)
    mov  ecx, dword ptr [rbx + PATCH_DESC.patch_len]
    lea  rax, [rbx + PATCH_DESC.repl_bytes]  ; src
    mov  r11d, dword ptr [rsp+80]             ; patch_off (zero-extended)
    add  r11, r13                             ; r11 = data + patch_off (dst)
main_apply:
    test ecx, ecx
    jle  main_apply_done
    movzx edx, byte ptr [rax]
    mov  byte ptr [r11], dl
    inc  rax
    inc  r11
    dec  ecx
    jmp  main_apply
main_apply_done:
    inc  esi                    ; applied++ (RSI untouched by copy loop)
    jmp  main_loop_next

main_already:
    lea  rcx, str_alr1
    call OutStr
    mov  ecx, dword ptr [rsp+80]   ; patch_off (r11 volatile across OutStr)
    call OutHex
    lea  rcx, str_alr2
    call OutStr
    inc  dword ptr [rsp+72]     ; already_count++
    jmp  main_loop_next

main_notfound:
    lea  rcx, str_notfound
    call OutStr
    inc  edi                    ; failed++

main_loop_next:
    inc  r15d
    jmp  main_loop

main_loop_end:
    lea  rcx, str_crlf
    call OutStr

    ; === evaluate results ===
    test edi, edi
    jnz  main_fail_version

    test esi, esi
    jz   main_all_already

    ; === backup + write ===
    mov  dword ptr [rsp+84], esi   ; save applied count (inline copy clobbers RSI/RDI)
    lea  rdi, g_backup
    lea  rsi, g_target
main_copy_path:
    mov  al, byte ptr [rsi]
    mov  byte ptr [rdi], al
    test al, al
    jz   main_copy_path_done
    inc  rsi
    inc  rdi
    jmp  main_copy_path
main_copy_path_done:
    ; append ".bak" (rdi points to null terminator)
    mov  dword ptr [rdi], 'k' shl 24 or 'a' shl 16 or 'b' shl 8 or '.'
    mov  byte ptr [rdi+4], 0

    ; CopyFileA(g_target, g_backup, FALSE)
    xor  r8d, r8d
    lea  rdx, g_backup
    lea  rcx, g_target
    call CopyFileA
    test eax, eax
    jz   main_err_bak

    lea  rcx, str_backup
    call OutStr

    ; open for writing
    mov  qword ptr [rsp+48], 0
    mov  dword ptr [rsp+40], FILE_ATTRIBUTE_NORMAL
    mov  dword ptr [rsp+32], CREATE_ALWAYS
    xor  r9d, r9d
    xor  r8d, r8d
    mov  edx, GENERIC_WRITE
    lea  rcx, g_target
    call CreateFileA
    cmp  rax, INVALID_HANDLE_VALUE
    je   main_err_writ
    mov  qword ptr [rsp+56], rax

    mov  qword ptr [rsp+32], 0
    mov  dword ptr [rsp+64], 0
    lea  r9, [rsp+64]
    mov  r8d, r14d
    mov  rdx, r13
    mov  rcx, qword ptr [rsp+56]
    call WriteFile
    mov  dword ptr [rsp+64], eax   ; save result (reuse bytesRW slot)
    mov  rcx, qword ptr [rsp+56]   ; hFile
    call CloseHandle
    mov  eax, dword ptr [rsp+64]
    test eax, eax
    jz   main_err_writ2

    ; free heap
    mov  r8, r13
    xor  edx, edx
    mov  rcx, r12
    call HeapFree

    cmp  dword ptr [rsp+84], 1   ; applied count (RSI clobbered by inline copy)
    je   main_done1
    lea  rcx, str_done2
    call OutStr
    jmp  main_exit0
main_done1:
    lea  rcx, str_done1
    call OutStr
    jmp  main_exit0

main_all_already:
    lea  rcx, str_alr_all
    call OutStr
    mov  r8, r13
    xor  edx, edx
    mov  rcx, r12
    call HeapFree
    jmp  main_exit0

main_fail_version:
    lea  rcx, str_fail_ver
    call OutStr
    mov  r8, r13
    xor  edx, edx
    mov  rcx, r12
    call HeapFree
    mov  ecx, 2
    call ExitProcess

main_err_writ2:
    lea  rcx, str_err_writ
    call OutStr
    mov  ecx, 4
    call ExitProcess

main_exit0:
    xor  ecx, ecx
    call ExitProcess

    ; --- error paths ---
main_nopath:
    lea  rcx, str_err_path
    call OutStr
    mov  ecx, 1
    call ExitProcess

main_err_open:
    lea  rcx, str_err_open
    call OutStr
    mov  ecx, 1
    call ExitProcess

main_err_size:
    mov  rcx, qword ptr [rsp+56]
    call CloseHandle
    lea  rcx, str_err_size
    call OutStr
    mov  ecx, 1
    call ExitProcess

main_err_mem:
    mov  rcx, qword ptr [rsp+56]
    call CloseHandle
    lea  rcx, str_err_mem
    call OutStr
    mov  ecx, 1
    call ExitProcess

main_err_read:
    mov  rcx, qword ptr [rsp+56]
    call CloseHandle
    mov  r8, r13
    xor  edx, edx
    mov  rcx, r12
    call HeapFree
    lea  rcx, str_err_read
    call OutStr
    mov  ecx, 1
    call ExitProcess

main_err_bak:
    mov  r8, r13
    xor  edx, edx
    mov  rcx, r12
    call HeapFree
    lea  rcx, str_err_bak
    call OutStr
    mov  ecx, 3
    call ExitProcess

main_err_writ:
    mov  r8, r13
    xor  edx, edx
    mov  rcx, r12
    call HeapFree
    lea  rcx, str_err_writ
    call OutStr
    mov  ecx, 4
    call ExitProcess

    ; Unreachable epilog (keeps unwind tables valid)
    add  rsp, 88
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    pop  rbp
    ret
mainCRTStartup endp

END
