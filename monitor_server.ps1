# --- KONFIGURASI ---
$webhookURL = "#"
$serverName = $env:COMPUTERNAME
$waktu = Get-Date -Format "dddd, dd MMMM yyyy HH:mm"

# 1. Monitoring Harddisk dengan Logika Warna
$diskReport = ""
$overallColor = 3066993 # Default Hijau

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

# 2. Monitoring Jaringan & Sesi User Lokal
$pingTest = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
$networkStatus = if ($pingTest) { "Online" } else { "Offline" }

# Mengambil jumlah sesi SMB aktif yang masuk ke server ini
$sessionCount = (Get-SmbSession).Count
if ($sessionCount -eq $null) { $sessionCount = 0 }

# 3. Monitoring RAM
$os = Get-WmiObject Win32_OperatingSystem
$freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)

# --- FORMAT PESAN DALAM EMBED ---
$embed = @{
    title = "LAPORAN SERVER: $serverName"
    description = "Waktu: $waktu"
    color = $overallColor
    fields = @(
        @{ name = "Status Jaringan"; value = $networkStatus; inline = $true },
        @{ name = "Sesi Akses"; value = "$sessionCount Perangkat"; inline = $true },
        @{ name = "Sisa RAM"; value = "$freeRAM GB dari $totalRAM GB"; inline = $true },
        @{ name = "Status Harddisk"; value = $diskReport; inline = $false }
    )
    footer = @{ text = "Monitoring System - PT Bias Teknoart Kreasindo" }
}

$payload = @{ embeds = @($embed) } | ConvertTo-Json -Depth 4

# --- KIRIM KE DISCORD ---
Invoke-RestMethod -Uri $webhookURL -Method Post -Body $payload -ContentType "application/json"

# --- FITUR TAMBAHAN: GENERATE REPORT HTML (UNTUK PDF) ---
$htmlPath = "C:\Reports\Laporan_$($serverName)_$(Get-Date -Format 'yyyyMMdd').html"

$htmlContent = @"
<html>
<head>
    <style>
        body { font-family: Arial; padding: 20px; }
        .header { background: #2c3e50; color: white; padding: 10px; text-align: center; }
        .status { padding: 10px; border: 1px solid #ddd; margin-top: 10px; }
        .safe { color: green; } .warning { color: orange; } .critical { color: red; }
    </style>
</head>
<body>
    <div class='header'><h1>Laporan Server $serverName</h1><p>$waktu</p></div>
    <div class='status'>
        <h3>Ringkasan Sistem:</h3>
        <p>Status Jaringan: $networkStatus</p>
        <p>User Aktif: $sessionCount</p>
        <p>Sisa RAM: $freeRAM GB / $totalRAM GB</p>
        <h3>Detail Storage:</h3>
        <pre>$diskReport</pre>
    </div>
</body>
</html>
"@

$htmlContent | Out-File -FilePath $htmlPath -Encoding utf8
