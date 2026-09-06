<#
    BG3Neuro smoke: one command for the vertical
    'connect -> state -> end_turn -> updated state'.

    No game, no Randy: FakeNeuroServer (mock Neuro WS) + mock BG3SE files.
    Scenario lives in test FullLoopSmokeTests (spec 9.4).

    Examples:
        powershell -ExecutionPolicy Bypass -File tests\smoke.ps1
        powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -Full        # whole test suite
        powershell -ExecutionPolicy Bypass -File tests\smoke.ps1 -SkipBuild

    Exit code: 0 = PASS, non-zero = FAIL.
#>
param(
    [switch]$SkipBuild,
    [switch]$Full
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$testProj = Join-Path $root "tests\BG3Neuro.Core.Tests\BG3Neuro.Core.Tests.csproj"
$log = Join-Path $env:TEMP ("bg3neuro-smoke-" + [guid]::NewGuid().ToString("N") + ".log")

Write-Host "== BG3Neuro smoke =="
Write-Host "root: $root"

if (-not $SkipBuild) {
    Write-Host "== build =="
    dotnet build (Join-Path $root "BG3Neuro.sln") --nologo -v q 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) {
        Write-Host "BUILD FAILED (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}

$label = if ($Full) { "full test suite" } else { "smoke FullLoopSmokeTests" }
Write-Host "== running $label =="

if ($Full) {
    dotnet test $testProj --no-build --nologo 2>&1 | Tee-Object -FilePath $log
} else {
    dotnet test $testProj --no-build --nologo --filter "FullyQualifiedName~FullLoopSmokeTests" 2>&1 | Tee-Object -FilePath $log
}

$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-Host "SMOKE PASS ($label)"
} else {
    Write-Host "SMOKE FAIL (exit $code) - details: $log"
}
exit $code