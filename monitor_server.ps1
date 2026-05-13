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
