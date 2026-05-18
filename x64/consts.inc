; ==============================================================================
; WSAPatch - consts.inc
; Win32 constants, structures and patch-specific definitions
; ==============================================================================

; --- File I/O ---
GENERIC_READ            EQU 80000000h
GENERIC_WRITE           EQU 40000000h
FILE_SHARE_READ         EQU 00000001h
FILE_ATTRIBUTE_NORMAL   EQU 00000080h
OPEN_EXISTING           EQU 3
CREATE_ALWAYS           EQU 2
INVALID_HANDLE_VALUE    EQU -1
INVALID_FILE_SIZE       EQU 0FFFFFFFFh

; --- Console ---
STD_OUTPUT_HANDLE       EQU -11

; --- Registry ---
HKLM                    EQU 80000002h
KEY_QUERY_VALUE         EQU 00000001h
ERROR_SUCCESS           EQU 0
REG_SZ                  EQU 1
REG_EXPAND_SZ           EQU 2

; --- Heap ---
HEAP_ZERO_MEMORY        EQU 00000008h

; --- Limits ---
MAX_PATH                EQU 260

; --- Scan result states ---
ST_NOT_FOUND            EQU -1
ST_NEEDS_PATCH          EQU 0
ST_ALREADY_PATCHED      EQU 1

; --- Patch descriptor layout (48 bytes, naturally aligned) ---
;   +0  name_ptr  QWORD   pointer to ANSI name string
;   +8  pre       BYTE[8] anchor bytes before patch site
;   +16 pre_len   DWORD   valid bytes in pre[]
;   +20 orig      BYTE[4] original bytes at patch site
;   +24 repl      BYTE[4] replacement bytes
;   +28 patch_len DWORD   bytes to patch (1..4)
;   +32 post      BYTE[8] anchor bytes after patch site
;   +40 post_len  DWORD   valid bytes in post[] (0 = skip)
;   +44 _pad      DWORD   alignment
PATCH_DESC STRUCT
    name_ptr    QWORD   ?
    pre         BYTE  8 dup(?)
    pre_len     DWORD   ?
    orig_bytes  BYTE  4 dup(?)
    repl_bytes  BYTE  4 dup(?)
    patch_len   DWORD   ?
    post        BYTE  8 dup(?)
    post_len    DWORD   ?
    _pad        DWORD   ?
PATCH_DESC ENDS

SIZEOF_PATCH_DESC       EQU 48
NUM_PATCHES             EQU 2
