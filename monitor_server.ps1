# --- KONFIGURASI ---
$webhookURL = "https://discord.com/api/webhooks/1503695823840612382/0ZFSlI4vtcSVvWFvY-e0esRSptROaDFz02-G3tnW4lEgOGGJFMwGtVOneVuGovdLO9eg"
$serverName = $env:COMPUTERNAME
$waktu = Get-Date -Format "dddd, dd MMMM yyyy HH:mm"

# 1. Monitoring Harddisk
$diskReport = Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
    $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
    $sizeGB = [math]::Round($_.Size / 1GB, 2)
    $percentFree = [math]::Round(($_.FreeSpace / $_.Size) * 100, 2)
    "Drive $($_.DeviceID) - Sisa: $freeGB GB ($percentFree%) dari $sizeGB GB"
}

# 2. Monitoring Jaringan
$pingTest = Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet
$networkStatus = if ($pingTest) { "Online" } else { "Offline" }

# 3. Monitoring RAM
$os = Get-WmiObject Win32_OperatingSystem
$freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
$totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)

# --- FORMAT PESAN (Gunakan Backtick-n untuk Baris Baru) ---
$line1 = "LAPORAN SERVER: $serverName"
$line2 = "Waktu: $waktu"
$line3 = "------------------------------------------"
$line4 = "Status Jaringan: $networkStatus"
$line5 = "Status Harddisk:"
$line6 = $diskReport -join "`n"
$line7 = "Sisa RAM: $freeRAM GB dari $totalRAM GB"

$finalMsg = "$line1`n$line2`n$line3`n$line4`n$line5`n$line6`n$line7"

# --- KIRIM KE DISCORD ---
$payload = @{
    content = $finalMsg
} | ConvertTo-Json

Invoke-RestMethod -Uri $webhookURL -Method Post -Body $payload -ContentType "application/json"