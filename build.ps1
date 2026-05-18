$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinDir    = Join-Path $ScriptDir "bin"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Building WSAPatch" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

$VSBASE = "C:\Program Files\Microsoft Visual Studio\18\Enterprise\VC\Tools\MSVC\14.50.35717\bin\Hostx64"
$ML64   = "$VSBASE\x64\ml64.exe"
$LINK64 = "$VSBASE\x64\link.exe"

$SDKBASE    = "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.22621.0"
$SDKBIN     = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64"
$LIBPATH_UM = "$SDKBASE\um\x64"

$env:PATH += ";$SDKBIN"

if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir | Out-Null
}

$FILES = @("io", "scan", "reg", "patch")
$LIBS  = @("kernel32.lib", "advapi32.lib")
$BuildOK = $true

if ($BuildOK) {
    Write-Host ""
    Write-Host ">>> Assembling x64" -ForegroundColor Cyan
    Push-Location $ScriptDir
    foreach ($f in $FILES) {
        Write-Host "  ml64: $f.asm" -ForegroundColor Gray
        & $ML64 /c /Cp /Cx /Zi /I x64 /Fo"x64\$f.obj" "x64\$f.asm"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: ml64 failed on $f.asm" -ForegroundColor Red
            $BuildOK = $false
            break
        }
    }
    Pop-Location
}

if ($BuildOK) {
    Write-Host ""
    Write-Host ">>> Linking" -ForegroundColor Cyan
    Push-Location $ScriptDir

    $objs = $FILES | ForEach-Object { "x64\$_.obj" }
    $linkArgs = $objs + @(
        "/subsystem:console",
        "/entry:mainCRTStartup",
        "/Brepro",
        "/NODEFAULTLIB",
        "/out:bin\WSAPatch.exe",
        "/MANIFEST:EMBED",
        "/MANIFESTUAC:level='requireAdministrator' uiAccess='false'",
        "/LIBPATH:$LIBPATH_UM"
    ) + $LIBS
    & $LINK64 $linkArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: link failed" -ForegroundColor Red
        $BuildOK = $false
    }
    Pop-Location
}

if ($BuildOK) {
    Write-Host ""
    Write-Host ">>> Verifying - no CRT imports" -ForegroundColor Cyan
    $DUMPBIN = "$VSBASE\x64\dumpbin.exe"
    $crt = & $DUMPBIN /imports "$BinDir\WSAPatch.exe" |
        Select-String "msvcr|vcruntime|ucrtbase"
    if ($crt) {
        Write-Host "WARNING: CRT dependency found!" -ForegroundColor Yellow
        $crt | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        $BuildOK = $false
    } else {
        Write-Host "[PASS] No CRT imports" -ForegroundColor Green
    }
}

# --- cleanup intermediates ---
Write-Host ""
Write-Host "Cleaning intermediates..." -ForegroundColor Yellow
Remove-Item "$ScriptDir\x64\*.obj" -ErrorAction SilentlyContinue

Write-Host ""
if ($BuildOK) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "STATUS: SUCCESS -> bin\WSAPatch.exe" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    exit 0
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "STATUS: FAILED" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    exit 1
}
