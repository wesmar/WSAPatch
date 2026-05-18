; ==============================================================================
; WSAPatch - scan.asm
; Anchor-based binary scan for patch sites
;
; Exports:
;   ScanPatch
;     RCX = PATCH_DESC*  pDesc
;     RDX = BYTE*        pData  (file image in heap)
;     R8D = DWORD        dwSize
;     R9  = DWORD*       pState (out: ST_NOT_FOUND / ST_NEEDS_PATCH / ST_ALREADY_PATCHED)
;     RAX = file offset of pre_anchor, or -1 (QWORD, sign-extended)
;
; Algorithm (matches patch.c):
;   window = pre_len + patch_len + post_len
;   for i = 0 .. size-window:
;     if data[i..] != pre[0..pre_len-1]: continue
;     if post_len > 0:
;       poff = i + pre_len + patch_len
;       if poff + post_len > size: continue
;       if data[poff..] != post[0..post_len-1]: continue
;     pp = data + i + pre_len
;     if pp[0..patch_len-1] == orig: *pState=NEEDS_PATCH, return i
;     if pp[0..patch_len-1] == repl: *pState=ALREADY_PATCHED, return i
;   *pState = NOT_FOUND, return -1
; ==============================================================================

option casemap:none

include consts.inc

.code

; ==============================================================================
; BytesCmp (internal) - compare ECX bytes at R8 vs R9
; Returns: ZF=1 equal, ZF=0 not equal
; Trashes: EAX, R8, R9, ECX
; ==============================================================================
BytesCmp proc
    test ecx, ecx
    jz  bcmp_equal
bcmp_loop:
    mov al, byte ptr [r8]
    cmp al, byte ptr [r9]
    jne bcmp_done
    inc r8
    inc r9
    dec ecx
    jnz bcmp_loop
bcmp_equal:
    xor eax, eax        ; set ZF=1 via TEST below
    test eax, eax
bcmp_done:
    ret
BytesCmp endp

; ==============================================================================
; ScanPatch
;
; Register map (non-volatile, saved in prologue):
;   RBX = i (outer loop index, QWORD)
;   RSI = limit (size - window, QWORD)
;   RDI = pState (out param, saved so inner calls don't clobber)
;   R12 = pDesc
;   R13 = pData
;   R14 = dwSize (zero-extended to QWORD)
;   R15 = (unused, reserved)
;
; Stack (8 pushes → RSP%16=8 at prologue end; sub 40 → 40%16=8 → RSP%16=0):
;   [rsp+0..31]  shadow space for BytesCmp
;   [rsp+32..39] (spare)
; ==============================================================================
ScanPatch proc frame
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
    sub  rsp, 40
    .allocstack 40
    .endprolog

    ; Save parameters
    mov  r12, rcx                           ; pDesc
    mov  r13, rdx                           ; pData
    mov  r14d, r8d                          ; dwSize (zero-extended)
    mov  rdi, r9                            ; pState

    ; Default: not found
    mov  dword ptr [rdi], ST_NOT_FOUND

    ; window = pre_len + patch_len + post_len
    mov  eax, dword ptr [r12 + PATCH_DESC.pre_len]
    add  eax, dword ptr [r12 + PATCH_DESC.patch_len]
    add  eax, dword ptr [r12 + PATCH_DESC.post_len]

    ; limit = size - window  (if negative: size < window, not found)
    mov  esi, r14d
    sub  esi, eax
    js   scan_notfound
    ; ESI is positive here (JS check above); writing to ESI zero-extends RSI automatically

    xor  rbx, rbx                           ; i = 0

scan_outer:
    cmp  rbx, rsi
    ja   scan_notfound

    ; --- compare pre_anchor: data[i..] vs pDesc->pre ---
    mov  ecx, dword ptr [r12 + PATCH_DESC.pre_len]
    lea  r8,  [r13 + rbx]                  ; ptr into data
    lea  r9,  [r12 + PATCH_DESC.pre]       ; ptr to pre bytes
    call BytesCmp
    jnz  scan_next

    ; --- compare post_anchor (if post_len > 0) ---
    mov  ecx, dword ptr [r12 + PATCH_DESC.post_len]
    test ecx, ecx
    jz   scan_check_patch

    ; poff = i + pre_len + patch_len
    mov  edx, dword ptr [r12 + PATCH_DESC.pre_len]
    add  edx, dword ptr [r12 + PATCH_DESC.patch_len]
    lea  r8,  [r13 + rbx]
    add  r8,  rdx                           ; data + poff

    ; verify poff + post_len <= size
    mov  eax, edx                           ; pre_len + patch_len
    add  eax, ecx                           ; + post_len
    add  rax, rbx                           ; + i
    cmp  rax, r14
    ja   scan_next                          ; would read past end

    ; compare post
    lea  r9,  [r12 + PATCH_DESC.post]
    call BytesCmp
    jnz  scan_next

scan_check_patch:
    ; pp = data + i + pre_len
    mov  edx, dword ptr [r12 + PATCH_DESC.pre_len]
    lea  r8,  [r13 + rbx]
    add  r8,  rdx                           ; r8 = pp

    mov  ecx, dword ptr [r12 + PATCH_DESC.patch_len]

    ; compare with orig
    lea  r9,  [r12 + PATCH_DESC.orig_bytes]
    push r8
    push rcx
    call BytesCmp
    pop  rcx
    pop  r8
    jnz  scan_try_repl
    mov  dword ptr [rdi], ST_NEEDS_PATCH
    mov  rax, rbx                           ; return i
    jmp  scan_done

scan_try_repl:
    lea  r9,  [r12 + PATCH_DESC.repl_bytes]
    call BytesCmp
    jnz  scan_next
    mov  dword ptr [rdi], ST_ALREADY_PATCHED
    mov  rax, rbx
    jmp  scan_done

scan_next:
    inc  rbx
    jmp  scan_outer

scan_notfound:
    mov  rax, -1

scan_done:
    add  rsp, 40
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    pop  rbp
    ret
ScanPatch endp

END
