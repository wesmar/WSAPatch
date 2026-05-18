# WSAPatch

**Binary patcher for WSABuilds 2407.40000.4.0 — fixes `STATUS_STOWED_EXCEPTION` crash on Windows 11 26H1 (build 28000+)**

> Applies two precise binary patches to `WsaClient.exe` so that Windows Subsystem for Android  
> survives the `AppUriHandlerRegistrationManager.UpdateAsync()` → `E_ACCESSDENIED` → `fail_fast` crash chain.

---

## The Problem

WSA (WSABuilds / MustardChef **2407.40000.4.0**) crashes within **a few seconds to ~40 seconds** on
Windows 11 **26H1** (build 10.0.28000+).  
Everything starts fine — the subsystem loads, apps launch — and then `WsaClient.exe` silently dies.

Exception code: **`STATUS_STOWED_EXCEPTION (0xC000027B)`**

---

## Debugging Session

### Step 1 — Capturing the crash dump

WER (Windows Error Reporting) was set to capture a full dump on `WsaClient.exe` crash.
Initial triage with CDB:

```
.ecxr
k 50
!analyze -v
```

Output pointed immediately to:

```
Faulting module:  combase!RoFailFastWithErrorContextInternal2
Stowed exception: ResultCode = 0x80070005 (E_ACCESSDENIED)
                  ExceptionAddress = WsaClient+0x82AEB
```

`STATUS_STOWED_EXCEPTION` is a WinRT mechanism: when a WinRT exception crosses the ABI boundary
without being caught, the runtime stores it ("stows" it) and later calls `RoFailFastWithErrorContext`.
The stored HRESULT was `E_ACCESSDENIED`.

### Step 2 — Identifying the WinRT interface

The stowed exception address led to a vtable pointer. Inspecting the interface GUID:

```
da WsaClient+0x35f788
dq WsaClient+0x316d58 L1
ln poi(WsaClient+0x316d58)
dq WsaClient+0x4ad278 L1
ln poi(WsaClient+0x4ad278)
```

Result:
- GUID `{D54DAC97-CB39-5F1F-883E-01853730BD6D}` → **`IAppUriHandlerRegistrationManagerStatics`**
- Symbol: `consume_Windows_System_IAppUriHandlerRegistrationManagerStatics<...>::GetDefault()`
- Further up the chain: `combase!RoFailFastWithErrorContext`, `ucrtbase!abort`

### Step 3 — Tracing the full call chain

```
IAppUriHandlerRegistrationManagerStatics::GetDefault()
  → IAsyncOperation::GetResults()         ; returns 0x80070005
  → test eax, eax / js WsaClient+0x82b0f ; jumps to error path
  → winrt::check_hresult(0x80070005)      ; throws C++ exception
  → [stack unwind]
  → catch-all block @ WsaClient+0x30dc5b
  → WsaClient+0x317f0
  → WsaClient+0x3f250
  → combase!RoFailFastWithErrorContext(0x80070005)
  → KERNELBASE!RaiseFailFastException
  → STATUS_STOWED_EXCEPTION → crash
```

Two independent crash points were found:

**Point A** — HRESULT dispatcher (13-entry dispatch table, one entry per known error code):
```asm
; WsaClient+0xC93D
cmp  ebx, 80070005h    ; E_ACCESSDENIED
jne  +0x19             ; 75 19 — skip to next entry
; falls through to fatal handler if matched
```

**Point B** — directly after `IAsyncOperation::GetResults()`:
```asm
; WsaClient+0x81EE5
call qword ptr [rdi+40h]   ; GetResults() → eax = 0x80070005
test eax, eax              ; SF=1 (HRESULT failure bit)
js   +0x26                 ; 78 26 — jump to error path
; should fall through to normal epilogue
```

### Step 4 — Why does the API return E_ACCESSDENIED on 26H1?

`AppUriHandlerRegistrationManager.UpdateAsync()` registers URI scheme handlers (deep links)
for MSIX/UWP/Android apps at runtime. WSA calls it at startup so Windows knows which Android
app should handle a given URI scheme.

Starting around build 28000 Microsoft tightened the capability requirements for this API —
it now requires `restrictedAppUriHandlerHost` or equivalent package trust level.
WSA's `AppxManifest.xml` declares `windows.appUriHandler` and `runFullTrust`, but that is
no longer sufficient on 26H1 and later builds.

The change appears to have been introduced in mid-2025 or earlier — based on reports in the
MustardChef issue tracker the crash affects various 26H1 builds, not just the latest ones.
On older production releases (22H2, 23H2) this code path either goes unreached or the API succeeds.

### Step 5 — Verifying the patches

After applying both patches, Opera for Android launched and stayed running past the previous crash point
mark. File Manager+ also worked. WSA remained stable.

The URI handler registration is silently skipped — deep links declared statically in
`AppxManifest.xml` remain registered; only the dynamic runtime update is omitted.
No functional impact on day-to-day app usage.

---

## The Two Patches

Both patches are located by **anchor-based scanning** (pre-bytes + post-bytes bracket the site),
not by fixed offsets — making the patcher robust against minor linker layout differences.

### Patch 1 — Bypass E_ACCESSDENIED in HRESULT dispatcher

| | |
|---|---|
| **File offset** | `0x0C943` |
| **RVA** | `0xD543` |
| **Original** | `75 19` — `JNE rel8 +0x19` |
| **Replacement** | `EB 19` — `JMP rel8 +0x19` |
| **Pre-anchor** | `81 FB 05 00 07 80` (`CMP EBX, 80070005h`) |
| **Post-anchor** | `19` (jump offset byte) |

Turns a conditional branch into an unconditional one: the dispatcher always skips to the
non-fatal path, so `E_ACCESSDENIED` is never routed to the fatal handler.

### Patch 2 — Ignore HRESULT from GetResults()

| | |
|---|---|
| **File offset** | `0x81EE7` |
| **RVA** | `0x82AE7` |
| **Original** | `78 26` — `JS rel8 +0x26` |
| **Replacement** | `90 90` — `NOP NOP` |
| **Pre-anchor** | `85 C0` (`TEST EAX, EAX`) |
| **Post-anchor** | `48 8B 4D` (next instruction prefix) |

Removes the signed-jump that redirected to the error path. Execution falls through to the
normal function epilogue, stack canary check and `ret` — no exception thrown, no crash.

---

## Usage

Run from an **elevated command prompt** (Administrator):

```
WSAPatch.exe [path\to\WsaClient.exe]
```

Without a path argument, WSAPatch discovers `WsaClient.exe` automatically via the registry:

```
HKLM\SYSTEM\CurrentControlSet\Services\WsaService\ImagePath
```

A `.bak` backup is created before any write. Running on an already-patched file prints
`Already patched` and exits cleanly (idempotent).

**Example output (fresh patch):**
```
WsaClient.exe patcher for Windows 11 26H1
==========================================
[*] No path given - searching via WsaService registry...
[*] Target: C:\wsa\WsaClient\WsaClient.exe
[*] Path found via registry

[*] Read 0x4DFC00 bytes

Patch 1: Bypass E_ACCESSDENIED check (JNE->JMP)
  [+] Found at 0xC93D, patching 0xC943: 75  -> EB

Patch 2: Ignore HRESULT from GetResults() (JS->NOP NOP)
  [+] Found at 0x81EE5, patching 0x81EE7: 78 26  -> 90 90

[*] Backup saved to *.bak
[*] Done. 2 patches applied.
```

---

## Requirements

- **Target:** WSABuilds / MustardChef **2407.40000.4.0** (`WsaClient.exe` SHA-256 verified by anchor scan)
- **OS:** Windows 11 26H1 (tested on build 10.0.28000.2113)
- **Elevation:** Administrator required (UAC manifest embedded)

---

## Building from Source

Requires **Visual Studio 2026 / Build Tools v18** (MASM x64 + LINK):

```powershell
.\build.ps1
```

Output: `bin\WSAPatch.exe` — verified no CRT imports by the build script (`dumpbin /imports`).

### Project layout

```
WSAPatch/
├── x64/
│   ├── consts.inc   Win32 constants, PATCH_DESC struct
│   ├── globals.inc  Exported data variable declarations
│   ├── io.asm       OutStr / OutHex / OutByte (WriteFile, no CRT)
│   ├── scan.asm     ScanPatch — anchor-based binary scan
│   ├── reg.asm      FindWsaPath — registry discovery
│   └── patch.asm    Entry point, patch table, orchestration
└── build.ps1        ML64 + LINK64, /NODEFAULTLIB, UAC manifest
```

### Technical highlights

- **Pure MASM x64** — zero CRT, zero C runtime, zero DLL dependencies beyond `kernel32` + `advapi32`
- **8.5 KB** final binary
- **Anchor-based scan** — finds patch sites by surrounding byte patterns, not fixed offsets
- **Full unwind tables** — proper `.pushreg` / `.allocstack` / `.endprolog` in every `proc frame`
- **UAC manifest embedded** — `/MANIFESTUAC:level='requireAdministrator'` via linker flag
- **Idempotent** — detects already-patched file, never double-patches

---

## Disclaimer

This patch is provided for **authorized use only** on systems you own or have explicit permission
to modify. Tested against a specific binary version; always keep the `.bak` backup.
The author is not responsible for any damage resulting from use of this software.

---

## License

MIT — see [LICENSE.md](LICENSE.md)

**Author:** Marek Wesołowski (WESMAR)  
**Contact:** marek@wesolowski.eu.org  
**GitHub:** https://github.com/wesmar/WSAPatch
