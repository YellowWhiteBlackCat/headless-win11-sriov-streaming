$ErrorActionPreference = 'Continue'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$logPath = 'C:\Program Files\Sunshine\config\sunshine.log'
$lines = Get-Content -Path $logPath -Encoding UTF8 -ErrorAction SilentlyContinue

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'device_id|display_name|friendly_name|DISPLAY\d|VDD|output_name') {
        $start = [Math]::Max(0, $i - 2)
        $end = [Math]::Min($lines.Count - 1, $i + 3)
        Write-Output "----- match at line $($i+1) -----"
        for ($j = $start; $j -le $end; $j++) {
            Write-Output $lines[$j]
        }
    }
}
