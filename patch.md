# WSA 2407.40000.4.0 — Crash fix: STATUS_STOWED_EXCEPTION / E_ACCESSDENIED

## Problem

Windows Subsystem for Android (WSABuilds / MustardChef, wersja **2407.40000.4.0**) crashuje
po ~35–40 sekundach od uruchomienia na Windows 11 Insider Preview build **10.0.28000** (26H1 Canary).
Proces `WsaClient.exe` kończy się wyjątkiem `STATUS_STOWED_EXCEPTION` (kod `0xC000027B`).

Z doniesień na issue trackera oryginalnego projektu wynika, że problem dotyka też wcześniejszych
build-ów serii 26H1 — wszystko od momentu gdy Microsoft zmienił uprawnienia do API
`AppUriHandlerRegistrationManager` w kanale deweloperskim.

---

## Analiza crash dump-ów (CDB / WinDbg)

### Dump 1 — surowy crash

```
.ecxr
k 50
!analyze -v
```

Wynik:
- Wyjątek: `STATUS_STOWED_EXCEPTION (0xC000027B)`
- Faulting address: `WsaClient+0x3f27f` → `combase!RoFailFastWithErrorContextInternal2`
- Stowed exception: `ResultCode = 0x80070005` (E_ACCESSDENIED), `ExceptionAddress = WsaClient+0x82AEB`

### Identyfikacja interfejsu

```
da WsaClient+0x35f788
dq WsaClient+0x316d58 L1
ln poi(WsaClient+0x316d58)
dq WsaClient+0x4ad278 L1
ln poi(WsaClient+0x4ad278)
```

Wyniki:
- `WsaClient+0x37cf38` → GUID `{D54DAC97-CB39-5F1F-883E-01853730BD6D}` = **IAppUriHandlerRegistrationManagerStatics**
- `WsaClient+0x37d4e0` → symbol: `consume_Windows_System_IAppUriHandlerRegistrationManagerStatics<...>::GetDefault(void) const`
- `WsaClient+0x316d58` → `ucrtbase!abort`
- `WsaClient+0x4ad278` → `combase!RoFailFastWithErrorContext`

### Łańcuch wywołań prowadzący do crasha

```
IAppUriHandlerRegistrationManagerStatics::GetDefault()
  → IAsyncOperation::GetResults()       ; zwraca 0x80070005 (E_ACCESSDENIED)
  → test eax,eax / js WsaClient+0x82b0f ; skok do ścieżki błędu
  → winrt::check_hresult(0x80070005)    ; rzuca wyjątek C++
  → [propagacja przez stos]
  → catch-all block @ WsaClient+0x30dc5b
  → WsaClient+0x317f0
  → WsaClient+0x3f250
  → combase!RoFailFastWithErrorContext(0x80070005)
  → KERNELBASE!RaiseFailFastException
  → STATUS_STOWED_EXCEPTION → crash
```

Niezależnie od powyższego, drugi punkt awarii:

```
; Dispatcher HRESULT @ WsaClient+0xd4e0
; 13-elementowa lista HRESULT-ów, każdy blok 0x21 bajtów:
;   cmp ebx, <HRESULT>
;   jne +0x19          ← PATCH 1 tutaj
;   mov r8,rdi
;   call <fatal_handler>
;   ...
;   int 3

cmp ebx, 80070005h    ; E_ACCESSDENIED
jne WsaClient+0xd55c  ; 75 19 — jeśli nie pasuje, skocz dalej
; → jeśli pasuje: wpada do obsługi fatal
```

---

## Dlaczego AppUriHandlerRegistrationManager zwraca E_ACCESSDENIED?

### Do czego służy ta funkcja

`AppUriHandlerRegistrationManager.UpdateAsync()` to WinRT API rejestrujące
**URI scheme handlery** (deep linki) dla aplikacji MSIX/UWP dynamicznie w czasie uruchomienia.
W kontekście WSA: każda apka Android może mieć własne URI scheme (np. `intent://`).
WSA próbuje te schematy zarejestrować przy starcie, żeby system Windows wiedział,
że dany URL powinien otworzyć konkretną apkę Androidową.

### Dlaczego przestało działać w 26H1

Od build-u ~28000 Microsoft zaostrzył wymagania dla tej API:
- Wymaga capability `restrictedAppUriHandlerHost` lub odpowiedniego poziomu uprawnień
- Albo API samo zostało ograniczone do sesji z pełnymi uprawnieniami pakietu
- AppxManifest WSA ma wprawdzie `windows.appUriHandler` (host: `WindowsSubsystemForAndroid.microsoft.com`)
  oraz capability `runFullTrust`, ale to nie wystarczy na nowych build-ach

Efekt: `GetDefault()` (lub `UpdateAsync()`) zwraca `E_ACCESSDENIED = 0x80070005`.
WsaClient traktuje to jako błąd krytyczny i wywołuje `fail_fast` → crash.

### Dlaczego wcześniej działało

Na starszych build-ach (przed 26H1 Canary) API było mniej restrykcyjne lub
WSA miało wewnętrzne uprawnienia systemowe które wystarczały. Na build-ach
produkcyjnych (np. 22H2, 23H2) WSA prawdopodobnie w ogóle nie trafi na ten problem,
bo ta ścieżka kodu albo nie jest wywoływana albo API działa poprawnie.

---

## Rozwiązanie — dwie poprawki binarne

### PATCH 1 — ominięcie fatal handlera w dyspatcherze HRESULT

| Parametr         | Wartość                              |
|------------------|--------------------------------------|
| Offset w pliku   | `0x0C943`                            |
| RVA              | `0xD543`                             |
| Oryginał         | `75 19` (JNE rel8 +0x19)            |
| Poprawka         | `EB 19` (JMP rel8 +0x19)            |

**Efekt:** Dispatcher HRESULT zawsze skacze dalej (do bloku non-fatal) zamiast
porównywać `ebx` z `0x80070005`. `E_ACCESSDENIED` nie trafia do fatal handlera.

### PATCH 3 — pominięcie ścieżki błędu po GetResults()

| Parametr         | Wartość                              |
|------------------|--------------------------------------|
| Offset w pliku   | `0x81EE7`                            |
| RVA              | `0x82AE7`                            |
| Oryginał         | `78 26` (JS rel8 +0x26)             |
| Poprawka         | `90 90` (NOP NOP)                   |

**Kontekst:**

```asm
; WsaClient+0x82AE1
call    qword ptr [rdi+40h]   ; IAsyncOperation::GetResults() → eax = 0x80070005
test    eax, eax              ; ustawia SF=1 (wynik ujemny → HRESULT failure)
js      WsaClient+0x82b0f    ; 78 26 — skok do ścieżki błędu ← NOP-ujemy to
; po NOP: fall-through do normalnego epilogu funkcji
mov     rcx, [rbp-10h]
xor     rcx, rsp              ; stack canary check
; → ret → normalne zakończenie → brak wyjątku → brak crasha
```

**Efekt:** `GetResults()` zwraca `E_ACCESSDENIED`, ale kod nie skacze do ścieżki błędu.
Rejestracja URI handlerów jest po cichu pominięta. WSA startuje normalnie.

---

## Pliki

| Plik                                   | Opis                              |
|----------------------------------------|-----------------------------------|
| `C:\wsa\WsaClient\WsaClient.exe.orig`  | Oryginał — bez zmian              |
| `C:\wsa\WsaClient\WsaClient.exe`       | Spatchowana wersja                |
| `C:\tcc\patch.c`                       | Kod patchera (TCC / WinAPI)       |

---

## Patcher (`patch.c`)

Napisany w C (Tiny C Compiler), zero zależności od CRT, czyste WinAPI.
Kilka KB. Wyszukuje ścieżkę do `WsaClient.exe` przez rejestr:

```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WsaService
```

Wartość `ImagePath` lub katalog instalacji → `\WsaClient\WsaClient.exe`.

Algorytm patchera:
1. Odczyt ścieżki z rejestru (`RegOpenKeyExW` / `RegQueryValueExW`)
2. Otwórz plik (`CreateFileW`, `GENERIC_READ | GENERIC_WRITE`)
3. Dla każdego patcha:
   - `SetFilePointerEx` → offset
   - `ReadFile` → weryfikacja oryginalnych bajtów (już spatchowany? → informacja)
   - `WriteFile` → zapis nowych bajtów
4. `CloseHandle`
5. `ExitProcess(0)`

---

## Skutki pominięcia rejestracji URI handlerów

Rejestracja URI handlerów w WSA służy do obsługi deep linków (np. otwierania apek
Androidowych z przeglądarki Windows przez kliknięcie linku). Po zastosowaniu patcha:

- Apki Androidowe **nadal działają** normalnie
- Deep linki z `AppxManifest.xml` (`WindowsSubsystemForAndroid.microsoft.com`) nadal
  są zarejestrowane statycznie — dynamiczna aktualizacja przez API jest jedynie pominięta
- Brak negatywnego wpływu na codzienne użytkowanie WSA

---

## Weryfikacja

Po nałożeniu patchów:
- Opera Android uruchamia się i działa po 35–40 sekundach (poprzedni limit crashu)
- File Manager+ działa
- WSA nie crashuje — wiatraki pracują, system stabilny

---

## Środowisko testowe

- Windows 11 Insider Preview **10.0.28000.1896** (Canary, 26H1)
- WSABuilds / MustardChef **2407.40000.4.0** (NoGApps, NoAmazon)
- Instalacja: `Add-AppxPackage -Register .\AppxManifest.xml` (tryb deweloperski)
- `IsDevelopmentMode: True`, brak `AppxBlockMap.xml` → brak weryfikacji hash-y przy starcie
