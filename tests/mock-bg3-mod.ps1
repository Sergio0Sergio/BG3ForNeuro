param(
    [string]$Dir = "$env:LOCALAPPDATA\Larian Studios\Baldur's Gate 3\Script Extender\BG3Neuro",
    [int]$IntervalSeconds = 2
)

$seq = 0
Write-Host "Mock BG3SE mod: heartbeat every ${IntervalSeconds}s into $Dir (Ctrl+C to stop)"
New-Item -ItemType Directory -Path $Dir -Force | Out-Null

try {
    while ($true) {
        $seq++
        $payload = @{
            mod       = "BG3Neuro"
            version   = "0.1.0"
            seq       = $seq
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText("$Dir\heartbeat.json", $payload)
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    Write-Host "`n[mock-mod] stopped"
}