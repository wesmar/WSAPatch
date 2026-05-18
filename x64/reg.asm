; ==============================================================================
; WSAPatch - reg.asm
; Registry-based WsaClient.exe path discovery
;
; Reads HKLM\SYSTEM\CurrentControlSet\Services\WsaService\ImagePath,
; strips the filename (WsaService.exe) and its directory (WsaService\),
; appends \WsaClient\WsaClient.exe.
;
; Structure on disk (always):
;   C:\wsa\WsaService\WsaService.exe   <- ImagePath
;   C:\wsa\WsaClient\WsaClient.exe     <- target
;
; Exports:
;   FindWsaPath  RCX=char* out  RDX=DWORD bufSize  ->  RAX=1 ok / 0 fail
; ==============================================================================

option casemap:none

include consts.inc

EXTRN OutStr:PROC
EXTRN RegOpenKeyExA:PROC
EXTRN RegQueryValueExA:PROC
EXTRN RegCloseKey:PROC
EXTRN ExpandEnvironmentStringsA:PROC

; ==============================================================================
; .data? - intermediate buffers (module-private, not exported)
; ==============================================================================
.data?

reg_raw      db 540 dup(?)  ; raw ImagePath from registry
reg_expanded db 540 dup(?)  ; after ExpandEnvironmentStringsA

; ==============================================================================
; .const - registry strings
; ==============================================================================
.const

str_svc_key  db 'S','Y','S','T','E','M','\','C','u','r','r','e','n','t','C','o','n','t','r','o','l','S','e','t','\','S','e','r','v','i','c','e','s','\','W','s','a','S','e','r','v','i','c','e',0
str_img_val  db 'I','m','a','g','e','P','a','t','h',0
str_wsa_sub  db '\','W','s','a','C','l','i','e','n','t','\','W','s','a','C','l','i','e','n','t','.','e','x','e',0

str_err_nokey  db '[!] WsaService not found in registry',13,10,0
str_err_noval  db '[!] WsaService\ImagePath missing',13,10,0
str_err_parse  db '[!] Cannot parse ImagePath',13,10,0
str_err_long   db '[!] Path too long',13,10,0

.code

; ==============================================================================
; StrLenA (internal) - ANSI string length, returns length in EAX (no null)
; RCX = string ptr
; ==============================================================================
StrLenA proc
    xor  eax, eax
@@:
    cmp  byte ptr [rcx+rax], 0
    je   @F
    inc  eax
    jmp  @B
@@:
    ret
StrLenA endp

; ==============================================================================
; StrCatA - append src (RDX) to end of dst (RCX). Exported for other modules.
; ==============================================================================
PUBLIC StrCatA
StrCatA proc
    ; find end of dst
    xor  eax, eax
@@:
    cmp  byte ptr [rcx+rax], 0
    je   @F
    inc  eax
    jmp  @B
@@:
    add  rcx, rax       ; rcx = dst end
    ; copy src
@@:
    mov  al, byte ptr [rdx]
    mov  byte ptr [rcx], al
    test al, al
    jz   @F
    inc  rcx
    inc  rdx
    jmp  @B
@@:
    ret
StrCatA endp

; ==============================================================================
; FindWsaPath
;
; Stack: 6 non-volatile pushes -> RSP%16=8; sub 88 -> 88%16=8 -> RSP%16=0.
;   [rsp+0..31]   shadow
;   [rsp+32..39]  5th param slot  (phkResult or lpData)
;   [rsp+40..47]  6th param slot  (lpcbData)
;   [rsp+48..55]  hKey QWORD local
;   [rsp+56..59]  type DWORD local
;   [rsp+60..63]  size DWORD local
;   [rsp+64..87]  spare
; ==============================================================================
FindWsaPath proc frame
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
    sub  rsp, 88
    .allocstack 88
    .endprolog

    mov  r12, rcx               ; out buffer
    mov  r13d, edx              ; bufSize

    ; --- RegOpenKeyExA(HKLM, str_svc_key, 0, KEY_QUERY_VALUE, &hKey) ---
    lea  rax, [rsp+48]          ; &hKey
    mov  qword ptr [rsp+32], rax ; 5th param = phkResult
    mov  r9d, KEY_QUERY_VALUE
    xor  r8d, r8d
    lea  rdx, str_svc_key
    mov  ecx, HKLM
    call RegOpenKeyExA
    test eax, eax
    jnz  fwp_nokey

    mov  rbx, qword ptr [rsp+48] ; hKey

    ; --- RegQueryValueExA(hKey, "ImagePath", NULL, &type, reg_raw, &size) ---
    mov  dword ptr [rsp+60], 540            ; size = sizeof(reg_raw)
    lea  rax, [rsp+60]
    mov  qword ptr [rsp+40], rax            ; 6th param = &size
    lea  rax, reg_raw
    mov  qword ptr [rsp+32], rax            ; 5th param = lpData
    lea  r9, [rsp+56]                       ; &type
    xor  r8d, r8d                           ; lpReserved = NULL
    lea  rdx, str_img_val
    mov  rcx, rbx
    call RegQueryValueExA
    test eax, eax
    jnz  fwp_noval

    mov  rcx, rbx
    call RegCloseKey

    ; --- strip surrounding quotes if present ---
    lea  rsi, reg_raw
    cmp  byte ptr [rsi], '"'
    jne  fwp_noquote
    inc  rsi                    ; skip opening quote
    ; find closing quote and zero it
    mov  rdi, rsi
fwp_findq:
    cmp  byte ptr [rdi], 0
    je   fwp_noquote
    cmp  byte ptr [rdi], '"'
    je   fwp_zeroq
    inc  rdi
    jmp  fwp_findq
fwp_zeroq:
    mov  byte ptr [rdi], 0
fwp_noquote:

    ; --- expand environment strings if REG_EXPAND_SZ ---
    mov  eax, dword ptr [rsp+56]            ; type
    cmp  eax, REG_EXPAND_SZ
    jne  fwp_noexpand
    mov  r8d, 540
    lea  rdx, reg_expanded
    mov  rcx, rsi
    call ExpandEnvironmentStringsA
    test eax, eax
    jz   fwp_noexpand
    lea  rsi, reg_expanded
fwp_noexpand:

    ; --- find last backslash (strip WsaService.exe) ---
    mov  rcx, rsi
    call StrLenA                ; eax = length of path string
    test eax, eax
    jz   fwp_parse_err

    ; scan backwards for '\'
    lea  rdi, [rsi + rax - 1]   ; rdi -> last char
fwp_back1:
    cmp  byte ptr [rdi], '\'
    je   fwp_found1
    dec  rdi
    cmp  rdi, rsi
    jb   fwp_parse_err
    jmp  fwp_back1
fwp_found1:
    mov  byte ptr [rdi], 0      ; truncate: now RSI = "C:\wsa\WsaService"

    ; --- find last backslash again (strip \WsaService directory) ---
    dec  rdi                    ; start one char before the zero we just set
fwp_back2:
    cmp  byte ptr [rdi], '\'
    je   fwp_found2
    dec  rdi
    cmp  rdi, rsi
    jb   fwp_parse_err
    jmp  fwp_back2
fwp_found2:
    mov  byte ptr [rdi], 0      ; truncate: now RSI = "C:\wsa"

    ; --- compute total length: strlen(rsi) + strlen("\WsaClient\WsaClient.exe") ---
    mov  rcx, rsi
    call StrLenA                ; eax = len of base dir
    add  eax, 24                ; + len of suffix (24 chars incl. null)
    cmp  eax, r13d
    jae  fwp_toolong

    ; --- build output: copy base, then append suffix ---
    mov  rcx, r12               ; out buffer
    mov  rdx, rsi               ; base dir
@@:
    mov  al, byte ptr [rdx]
    mov  byte ptr [rcx], al
    test al, al
    jz   @F
    inc  rcx
    inc  rdx
    jmp  @B
@@:
    ; append \WsaClient\WsaClient.exe
    lea  rdx, str_wsa_sub
    mov  rcx, r12
    call StrCatA

    mov  eax, 1                 ; success
    jmp  fwp_done

fwp_nokey:
    lea  rcx, str_err_nokey
    call OutStr
    xor  eax, eax
    jmp  fwp_done

fwp_noval:
    mov  rcx, rbx
    call RegCloseKey
    lea  rcx, str_err_noval
    call OutStr
    xor  eax, eax
    jmp  fwp_done

fwp_parse_err:
    lea  rcx, str_err_parse
    call OutStr
    xor  eax, eax
    jmp  fwp_done

fwp_toolong:
    lea  rcx, str_err_long
    call OutStr
    xor  eax, eax

fwp_done:
    add  rsp, 88
    pop  r13
    pop  r12
    pop  rdi
    pop  rsi
    pop  rbx
    pop  rbp
    ret
FindWsaPath endp

END
