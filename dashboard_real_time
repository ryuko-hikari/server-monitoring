$messageID = "" 

while($true) {
    $waktu = (Get-Date).ToString("HH:mm:ss")
    
    try {
        $cpu = [math]::Round((Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 1)
        $os = Get-WmiObject Win32_OperatingSystem
        $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        $usedRAM = [math]::Round($totalRAM - $freeRAM, 2)
        $ssn = (Get-SmbSession).Count
        if ($ssn -eq $null) { $ssn = 0 }

        $json = @{
            embeds = @(@{
                title = "DASHBOARD REAL-TIME: BITEK-002"
                description = "Terakhir Update: **$waktu**"
                color = 3066993
                fields = @(
                    @{ name = "CPU Load"; value = "$cpu %"; inline = $true },
                    @{ name = "RAM"; value = "$usedRAM / $totalRAM GB"; inline = $true },
                    @{ name = "Sesi Aktif"; value = "$ssn Perangkat"; inline = $false }
                )
            })
        } | ConvertTo-Json -Depth 4

        if ($messageID -eq "") {
            # WEBHOOK LANGSUNG DI SINI
            $res = Invoke-RestMethod -Uri "#?wait=true" -Method Post -Body $json -ContentType "application/json"
            $messageID = $res.id
            Write-Host "Dashboard Baru Dibuat! ID: $messageID" -ForegroundColor Cyan
        } else {
            $editURL = "#/messages/$messageID"
            Invoke-RestMethod -Uri $editURL -Method Patch -Body $json -ContentType "application/json"
            Write-Host "Update Sukses: $waktu" -ForegroundColor Green
        }
    } catch {
        Write-Host "Gagal Update: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Start-Sleep -Seconds 300
}
