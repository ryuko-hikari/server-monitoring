# --- KONFIGURASI ---
$webhookURL = "#"
$serverName = $env:COMPUTERNAME
$waktuSekarang = Get-Date
$waktuFormat = $waktuSekarang.ToString("dddd, dd MMMM yyyy HH:mm")

# --- LOGIKA DURASI (JAM 8 PAGI - 5 SORE) ---
$jamMulai = 8
$jamSelesai = 17

if ($waktuSekarang.Hour -ge $jamMulai -and $waktuSekarang.Hour -lt $jamSelesai) {

    # 1. Monitoring Harddisk
    $diskReport = ""
    $overallColor = 3066993 
    Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
        $sizeGB = [math]::Round($_.Size / 1GB, 2)
        $percentFree = [math]::Round(($_.FreeSpace / $_.Size) * 100, 2)
        
        if ($percentFree -lt 20) {
            $indicator = '```diff' + "`n" + '- [CRITICAL]' + "`n" + '```'
            $overallColor = 15158332 
        } elseif ($percentFree -lt 50) {
            $indicator = '```fix' + "`n" + '[WARNING]' + "`n" + '```'
            if ($overallColor -ne 15158332) { $overallColor = 15844367 } 
        } else {
            $indicator = '```diff' + "`n" + '+ [SAFE]' + "`n" + '```'
        }
        $diskReport += "Drive $($_.DeviceID) $indicator Sisa: $freeGB GB ($percentFree %) dari $sizeGB GB`n"
    }

    # 2. Monitoring Sistem & User
    $networkStatus = if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet) { "Online" } else { "Offline" }
    $sessionCount = (Get-SmbSession).Count
    if ($sessionCount -eq $null) { $sessionCount = 0 }
    $os = Get-WmiObject Win32_OperatingSystem
    $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)

    # 3. KIRIM KE DISCORD (EMBED)
    $embed = @{
        title = "LAPORAN SERVER (SHIFT KERJA): $serverName"
        description = "Waktu: $waktuFormat"
        color = $overallColor
        fields = @(
            @{ name = "Status Jaringan"; value = $networkStatus; inline = $true },
            @{ name = "Sesi Akses"; value = "$sessionCount Perangkat"; inline = $true },
            @{ name = "Sisa RAM"; value = "$freeRAM GB dari $totalRAM GB"; inline = $true },
            @{ name = "Status Harddisk"; value = $diskReport; inline = $false }
        )
        footer = @{ text = "Monitoring System" }
    }
    $payload = @{ embeds = @($embed) } | ConvertTo-Json -Depth 4
    Invoke-RestMethod -Uri $webhookURL -Method Post -Body $payload -ContentType "application/json"

    # 4. GENERATE REPORT (FORMAT SIAP PDF)
    $reportDir = "C:\Reports"
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir }
    $htmlPath = "$reportDir\Laporan_Shift_$($serverName)_$(Get-Date -Format 'yyyyMMdd_HHmm').html"

    $htmlContent = @"
    <!DOCTYPE html>
    <html>
    <head>
        <style>
            body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; padding: 40px; line-height: 1.6; color: #333; }
            .header { background: #2c3e50; color: white; padding: 20 : text-align: center; border-radius: 8px 8px 0 0; }
            .container { border: 1px solid #ddd; border-radius: 0 0 8px 8px; padding: 20px; background: #f9f9f9; }
            .metric { margin-bottom: 15px; padding: 10px; border-bottom: 1px solid #eee; }
            .metric strong { color: #2c3e50; }
            .footer { margin-top: 30px; font-size: 0.8em; text-align: center; color: #7f8c8d; }
            @media print { .no-print { display: none; } }
        </style>
    </head>
    <body>
        <div class='header'>
            <h1>LAPORAN HARIAN SERVER</h1>
            <p>$serverName | Shift: 08:00 - 17:00</p>
        </div>
        <div class='container'>
            <div class='metric'><strong>Waktu Laporan:</strong> $waktuFormat</div>
            <div class='metric'><strong>Status Jaringan:</strong> $networkStatus</div>
            <div class='metric'><strong>Sesi User Aktif:</strong> $sessionCount Perangkat</div>
            <div class='metric'><strong>Kesehatan RAM:</strong> $freeRAM GB Tersedia dari $totalRAM GB</div>
            <div class='metric'>
                <strong>Detail Penyimpanan:</strong>
                <pre style="background: #eee; padding: 15px; border-radius: 5px;">$diskReport</pre>
            </div>
        </div>
        <div class='footer'>Laporan Internal IT</div>
        <center class='no-print'><br><button onclick='window.print()'>Cetak / Simpan ke PDF</button></center>
    </body>
    </html>
"@
    $htmlContent | Out-File -FilePath $htmlPath -Encoding utf8
    Write-Host "Laporan Shift Berhasil Dibuat: $htmlPath" -ForegroundColor Green

} else {
    Write-Host "Di luar jam operasional (08:00 - 17:00). Laporan tidak dibuat." -ForegroundColor Yellow
}
