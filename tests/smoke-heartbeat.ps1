param(
    [string]$AppExe = "$PSScriptRoot\..\src\BG3Neuro.App\bin\Debug\net9.0\BG3Neuro.App.exe"
)

$ErrorActionPreference = "Stop"
$tmp = Join-Path $env:TEMP ("bg3neuro-smoke-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$app = $null
$mock = $null

try {
    $config = @{
        neuro = @{ ws_url = "ws://localhost:8000"; reconnect_interval_s = 3 }
        ipc   = @{
            dir                  = $tmp
            state_file           = "bg3_to_neuro.json"
            command_file         = "neuro_to_bg3.json"
            poll_interval_ms     = 50
            heartbeat_interval_s = 2
            heartbeat_stale_s    = 10
        }
        game  = @{ name = "Baldur's Gate 3"; controlledPartySize = 1 }
    } | ConvertTo-Json -Depth 8
    $configPath = Join-Path $tmp "config.json"
    [System.IO.File]::WriteAllText($configPath, $config)

    Write-Host "== Phase 1: App running, no mod (wait 3s) -> no Alive expected =="
    $appLog = Join-Path $tmp "app.log"
    $app = Start-Process -FilePath $AppExe -ArgumentList $configPath -PassThru -NoNewWindow -RedirectStandardOutput $appLog
    Start-Sleep -Seconds 3
    Write-Host (Get-Content $appLog -Raw)

    Write-Host "== Phase 2: start mock mod (heartbeat 2s, wait 5s) -> Alive expected =="
    $mockLog = Join-Path $tmp "mock.log"
    $mock = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$PSScriptRoot\mock-bg3-mod.ps1", "-Dir", $tmp, "-IntervalSeconds", 2 -PassThru -NoNewWindow -RedirectStandardOutput $mockLog
    Start-Sleep -Seconds 5
    Write-Host (Get-Content $appLog -Raw)

    Write-Host "== Phase 3: stop mock mod (wait 12s) -> Stale expected =="
    if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force }
    Start-Sleep -Seconds 12
    Write-Host (Get-Content $appLog -Raw)

    Write-Host "== Smoke done =="
}
finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
    if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}