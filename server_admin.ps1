$webhookURL = "#"
$port = 8081

# Bersihkan port agar tidak terjadi konflik
$old = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
if ($old) { Stop-Process -Id $old.OwningProcess -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://*:$port/")
$listener.Start()

# Variabel Global Server
$activeUsers = @{}
$timeoutSeconds = 300
$global:lockedFiles = @{} 

Write-Host "--- SERVER FILE MANAGER ---" -ForegroundColor Cyan
Write-Host "URL Akses: http://localhost:$port/list" -ForegroundColor Green

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $req = $context.Request
    $res = $context.Response
    
    # --- SISTEM PELACAKAN USER AKTIF ---
    $clientIP = $req.RemoteEndPoint.Address.ToString()
    if ($clientIP -eq "::1") { $clientIP = "127.0.0.1" }
    $activeUsers[$clientIP] = [datetime]::Now

    $now = [datetime]::Now
    $keysToInspect = @($activeUsers.Keys)
    foreach ($key in $keysToInspect) {
        if (($now - $activeUsers[$key]).TotalSeconds -gt $timeoutSeconds) {
            $activeUsers.Remove($key)
        }
    }

    $currentPath = $req.QueryString["dir"]
    if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = "C:\" }
    if (-not (Test-Path -LiteralPath $currentPath -ErrorAction SilentlyContinue)) { $currentPath = "C:\" }

    $q = $req.QueryString["q"]

    try {
        # --- ROUTING ENDPOINT STATS ---
        if ($req.Url.AbsolutePath -eq "/stats") {
            try {
                $cpuObj = Get-WmiObject Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average
                $cpu = if ($cpuObj) { $cpuObj.Average } else { 0 }
                $ram = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
                $totalRam = [math]::Round($ram.TotalVisibleMemorySize / 1048576, 1)
                $freeRam = [math]::Round($ram.FreePhysicalMemory / 1048576, 1)
                $usedRam = [math]::Round(($totalRam - $freeRam), 1)
                $ramPct = if ($totalRam -gt 0) { [math]::Round(($usedRam / $totalRam) * 100, 0) } else { 0 }
                
                $serverIp = "127.0.0.1"
                $ips = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Virtual|Tailscale|Npcap|VMware' -and $_.IPAddress -notmatch '^169\.254\.' }
                if ($ips) {
                    $prefIp = $ips | Where-Object { $_.IPAddress -match '^192\.168\.' } | Select-Object -First 1
                    $serverIp = if ($prefIp) { $prefIp.IPAddress } else { $ips[0].IPAddress }
                }
                
                $stats = @{ cpu = $([math]::Round($cpu,1)); usedRam = $usedRam; totalRam = $totalRam; ramPct = $ramPct; activeUsers = $activeUsers.Count; serverIp = $serverIp }
            } catch { $stats = @{ cpu = 0; usedRam = 0; totalRam = 0; ramPct = 0; activeUsers = $activeUsers.Count; serverIp = "Error" } }
            $json = $stats | ConvertTo-Json
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
            $res.ContentType = "application/json; charset=utf-8"
            $res.OutputStream.Write($buffer, 0, $buffer.Length)
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT TOGGLE LOCK ---
        if ($req.Url.AbsolutePath -eq "/toggle-lock") {
            $pathLock = $req.QueryString["path"]
            $redir = $req.QueryString["redir"]
            
            if ($global:lockedFiles.ContainsKey($pathLock)) {
                $global:lockedFiles.Remove($pathLock)
                $alert = "unlock_ok"
            } else {
                $global:lockedFiles[$pathLock] = $clientIP
                $alert = "lock_ok"
            }
            $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=$alert")
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT SAVE TEXT ---
        if ($req.Url.AbsolutePath -eq "/save-text" -and $req.HttpMethod -eq "POST") {
            $pathSave = $req.QueryString["path"]
            
            if ($global:lockedFiles.ContainsKey($pathSave) -and $global:lockedFiles[$pathSave] -ne $clientIP) {
                $res.StatusCode = 403; $buffer = [System.Text.Encoding]::UTF8.GetBytes("LOCKED"); $res.OutputStream.Write($buffer, 0, $buffer.Length); $res.OutputStream.Close(); continue
            }

            $reader = New-Object System.IO.StreamReader($req.InputStream)
            $newContent = $reader.ReadToEnd()
            
            try {
                [System.IO.File]::WriteAllText($pathSave, $newContent, [System.Text.Encoding]::UTF8)
                try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📝 **[ADMIN CRUD]**: File teks $pathSave telah diedit via Web Editor."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                $res.StatusCode = 200; $buffer = [System.Text.Encoding]::UTF8.GetBytes("OK")
            } catch {
                $res.StatusCode = 500; $buffer = [System.Text.Encoding]::UTF8.GetBytes($_.Exception.Message)
            }
            $res.OutputStream.Write($buffer, 0, $buffer.Length)
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT MOVE ---
        if ($req.Url.AbsolutePath -eq "/move") {
            $src = $req.QueryString["src"]
            $dest = $req.QueryString["dest"]
            
            if ($global:lockedFiles.ContainsKey($src) -or $global:lockedFiles.ContainsKey($dest)) {
                $res.StatusCode = 500; $buffer = [System.Text.Encoding]::UTF8.GetBytes("File ini sedang DIKUNCI oleh user lain."); $res.OutputStream.Write($buffer, 0, $buffer.Length); $res.OutputStream.Close(); continue
            }

            try {
                # [PERBAIKAN] Pengecekan cerdas agar tidak error saat folder drop ke diri sendiri
                $srcNorm = (Get-Item -LiteralPath $src -ErrorAction SilentlyContinue).FullName
                $destNorm = (Get-Item -LiteralPath $dest -ErrorAction SilentlyContinue).FullName
                $srcParentNorm = (Split-Path -LiteralPath $src -Parent)

                if ($srcNorm -and $destNorm) {
                    if ($srcNorm -eq $destNorm -or $srcParentNorm -eq $destNorm) {
                        $res.StatusCode = 200; $buffer = [System.Text.Encoding]::UTF8.GetBytes("OK"); $res.OutputStream.Write($buffer, 0, $buffer.Length); $res.OutputStream.Close(); continue
                    }
                    if ($destNorm.StartsWith($srcNorm + "\")) {
                        $res.StatusCode = 400; $buffer = [System.Text.Encoding]::UTF8.GetBytes("Tidak dapat memindah folder ke dalam dirinya sendiri."); $res.OutputStream.Write($buffer, 0, $buffer.Length); $res.OutputStream.Close(); continue
                    }
                }

                Move-Item -LiteralPath $src -Destination $dest -Force -ErrorAction Stop
                try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="🔄 **[ADMIN CRUD]**: Memindahkan $src ke $dest."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                $res.StatusCode = 200; $buffer = [System.Text.Encoding]::UTF8.GetBytes("OK"); $res.OutputStream.Write($buffer, 0, $buffer.Length)
            } catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match "Access to the path") { $errMsg = "Akses Ditolak! Solusi: Jalankan ulang PowerShell dengan mode 'Run as Administrator'." }
                $res.StatusCode = 500; $buffer = [System.Text.Encoding]::UTF8.GetBytes($errMsg); $res.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT RENAME ---
        if ($req.Url.AbsolutePath -eq "/rename") {
            $targetOldPath = $req.QueryString["path"]
            $newName = $req.QueryString["newName"]
            $redir = $req.QueryString["redir"]
            
            $targetDir = Split-Path $targetOldPath
            $newFullPath = Join-Path $targetDir $newName

            if ($global:lockedFiles.ContainsKey($targetOldPath) -or $global:lockedFiles.ContainsKey($newFullPath)) {
                $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=locked_error"); $res.OutputStream.Close(); continue
            }

            if (Test-Path -LiteralPath $targetOldPath) {
                $oldName = (Get-Item -LiteralPath $targetOldPath).Name
                if ($oldName -ne $newName) {
                    try {
                        Rename-Item -LiteralPath $targetOldPath -NewName $newName -Force -ErrorAction Stop
                        try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="✏️ **[ADMIN CRUD]**: Mengubah nama $oldName menjadi $newName"}|ConvertTo-Json) -ContentType "application/json" } catch {}
                        $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=rename_ok")
                    } catch {
                        $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=in_use_error")
                    }
                } else { $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))") }
            } else { $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))") }
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT BULK DELETE ---
        if ($req.Url.AbsolutePath -eq "/bulk-delete" -and $req.HttpMethod -eq "POST") {
            $reader = New-Object System.IO.StreamReader($req.InputStream)
            $body = $reader.ReadToEnd() | ConvertFrom-Json
            
            $hasError = $false
            foreach ($itemSelected in $body.paths) {
                $fullDelPath = Join-Path $currentPath $itemSelected
                if ($global:lockedFiles.ContainsKey($fullDelPath)) { $hasError = $true; continue }

                if (Test-Path -LiteralPath $fullDelPath) {
                    try { Remove-Item -LiteralPath $fullDelPath -Recurse -Force -ErrorAction Stop } catch { $hasError = $true }
                }
            }
            
            if ($hasError) {
                $res.StatusCode = 409
                $buffer = [System.Text.Encoding]::UTF8.GetBytes("IN_USE")
            } else {
                try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="🗑️ **[ADMIN CRUD]**: Menghapus massal sebanyak $($body.paths.Count) item."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                $res.StatusCode = 200; $buffer = [System.Text.Encoding]::UTF8.GetBytes("OK")
            }
            $res.OutputStream.Write($buffer, 0, $buffer.Length)
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT BULK DOWNLOAD AS ZIP ---
        if ($req.Url.AbsolutePath -eq "/bulk-download" -and $req.HttpMethod -eq "POST") {
            $reader = New-Object System.IO.StreamReader($req.InputStream)
            $rawBody = $reader.ReadToEnd()
            
            if ($rawBody -match "(?:^|&)paths=([^&]*)") {
                $encodedPaths = $matches[1]
                $decodedVal = [Uri]::UnescapeDataString($encodedPaths.Replace('+', ' '))
                $pathsArray = $decodedVal -split '\|'
                
                $tempDir = [System.IO.Path]::GetTempPath()
                $tempZipPath = Join-Path $tempDir ("bulk_download_" + (Get-Date -Format "yyyyMMddHHmmss") + ".zip")
                $tempFolder = Join-Path $tempDir ([System.IO.Path]::GetRandomFileName())
                New-Item -ItemType Directory -Path $tempFolder | Out-Null
                
                $hasEmptyFolder = $false
                foreach ($p in $pathsArray) {
                    if ([string]::IsNullOrWhiteSpace($p)) { continue }
                    $sourceItem = Join-Path $currentPath $p
                    if (Test-Path -LiteralPath $sourceItem) { 
                        $isDir = (Get-Item -LiteralPath $sourceItem).PSIsContainer
                        if ($isDir) {
                            $hasFiles = Get-ChildItem -LiteralPath $sourceItem -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                            if (-not $hasFiles) { $hasEmptyFolder = $true; continue }
                        }
                        try { Copy-Item -LiteralPath $sourceItem -Destination $tempFolder -Recurse -Force -ErrorAction Stop } catch {} 
                    }
                }
                
                $allFiles = Get-ChildItem -LiteralPath $tempFolder -Recurse -File -ErrorAction SilentlyContinue
                if (-not $allFiles) {
                    Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
                    $res.StatusCode = 400; $buffer = [System.Text.Encoding]::UTF8.GetBytes("Folder kosong"); $res.OutputStream.Write($buffer, 0, $buffer.Length); $res.OutputStream.Close(); continue
                }
                
                try { Compress-Archive -Path "$tempFolder\*" -DestinationPath $tempZipPath -Force -ErrorAction Stop } catch {}
                Remove-Item -LiteralPath $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
                
                if (Test-Path -LiteralPath $tempZipPath) {
                    $fileBytes = [System.IO.File]::ReadAllBytes($tempZipPath)
                    if ($hasEmptyFolder) { $res.AddHeader("X-Download-Warning", "empty_skipped") }
                    
                    $res.ContentType = "application/octet-stream"
                    $res.AddHeader("Content-Disposition", "attachment; filename=""bulk_download.zip""")
                    $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    Remove-Item -LiteralPath $tempZipPath -Force -ErrorAction SilentlyContinue
                    try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📥 **[ADMIN CRUD]**: Bulk download ZIP dijalankan."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                } else {
                    $res.StatusCode = 500; $buffer = [System.Text.Encoding]::UTF8.GetBytes("Gagal arsip"); $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
            } else {
                $res.StatusCode = 400; $buffer = [System.Text.Encoding]::UTF8.GetBytes("Bad Request"); $res.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT ZIP FOLDER ---
        if ($req.Url.AbsolutePath -eq "/zipfolder") {
            $pathZip = $req.QueryString["path"]
            $redir = $req.QueryString["redir"]
            
            if (Test-Path -LiteralPath $pathZip) {
                $zipName = (Get-Item -LiteralPath $pathZip).Name + ".zip"
                $destZip = Join-Path $redir $zipName
                
                if ($global:lockedFiles.ContainsKey($destZip)) {
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=locked_error"); $res.OutputStream.Close(); continue
                }

                if (Test-Path -LiteralPath $destZip) { Remove-Item -LiteralPath $destZip -Force }
                try {
                    Compress-Archive -LiteralPath $pathZip -DestinationPath $destZip -Force -ErrorAction Stop
                    try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="🗜️ **[ADMIN CRUD]**: Folder $pathZip dijadikan zip."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=zip_ok")
                } catch {
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=in_use_error")
                }
            } else { $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))") }
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT EXTRACT ---
        if ($req.Url.AbsolutePath -eq "/extract") {
            $pathExt = $req.QueryString["path"]
            $redir = $req.QueryString["redir"]
            $ext = [System.IO.Path]::GetExtension($pathExt).ToLower()
            
            if ($ext -eq ".zip") {
                try {
                    Expand-Archive -LiteralPath $pathExt -DestinationPath $redir -Force -ErrorAction Stop
                    try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📦 **[ADMIN CRUD]**: File ZIP $pathExt diekstrak."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=extract_ok")
                } catch {
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=in_use_error")
                }
            } 
            elseif ($ext -eq ".rar") {
                $winrar = "C:\Program Files\WinRAR\UnRAR.exe"; $winrarAlt = "C:\Program Files\WinRAR\WinRAR.exe"; $sevenzip = "C:\Program Files\7-Zip\7z.exe"
                $extracted = $false
                if (Test-Path -LiteralPath $winrar) { & $winrar x -y "$pathExt" "$redir\" | Out-Null; $extracted = $true } 
                elseif (Test-Path -LiteralPath $winrarAlt) { & $winrarAlt x -y "$pathExt" "$redir\" | Out-Null; $extracted = $true } 
                elseif (Test-Path -LiteralPath $sevenzip) { & $sevenzip x "$pathExt" "-o$redir\" -y | Out-Null; $extracted = $true }
                
                if ($extracted) {
                    try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📦 **[ADMIN CRUD]**: File RAR $pathExt diekstrak."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=extract_ok")
                } else { $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=no_rar_tool") }
            }
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT PRINT ---
        if ($req.Url.AbsolutePath -eq "/print") {
            $pathPrint = $req.QueryString["path"]
            if (Test-Path -LiteralPath $pathPrint -PathType Leaf) { 
                $ext = [System.IO.Path]::GetExtension($pathPrint).ToLower()
                $fileName = (Get-Item -LiteralPath $pathPrint).Name
                $htmlPrint = "<html><head><meta charset='UTF-8'><meta name='viewport' content='width=device-width, initial-scale=1.0'><title>Print - $fileName</title></head><body onload='window.print();' style='font-family:monospace; padding:20px;'><h3 style='color:gray;'>Dokumen: $fileName</h3><hr>"
                if ($ext -match "\.(txt|log|ps1|ini|csv|json|xml|html|css|js)$") { $textContent = [System.IO.File]::ReadAllText($pathPrint); $textContent = $textContent.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;"); $htmlPrint += "<pre style='white-space: pre-wrap; word-wrap: break-word;'>$textContent</pre>" } 
                elseif ($ext -match "\.(jpg|jpeg|png|gif|bmp|webp)$") { $htmlPrint += "<img src='/preview?path=$([Uri]::EscapeDataString($pathPrint))' style='max-width:100%;'>" } 
                else { $htmlPrint += "<p>Tipe file tidak didukung cetak langsung.</p>" }
                $htmlPrint += "</body></html>"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($htmlPrint); $res.ContentType = "text/html; charset=utf-8"; $res.OutputStream.Write($buffer, 0, $buffer.Length)
            } else { 
                $res.StatusCode = 404; $buffer = [System.Text.Encoding]::UTF8.GetBytes("File tidak ditemukan."); $res.OutputStream.Write($buffer, 0, $buffer.Length) 
            }
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT PREVIEW ---
        if ($req.Url.AbsolutePath -eq "/preview") {
            $pathPreview = $req.QueryString["path"]
            if (Test-Path -LiteralPath $pathPreview -PathType Leaf) { 
                try {
                    $fileBytes = [System.IO.File]::ReadAllBytes($pathPreview)
                    $fileName = (Get-Item -LiteralPath $pathPreview).Name
                    $ext = [System.IO.Path]::GetExtension($pathPreview).ToLower()
                    $mimeType = switch ($ext) { 
                        ".txt" {"text/plain"} ".log" {"text/plain"} ".ps1" {"text/plain"} ".ini" {"text/plain"} ".csv" {"text/csv"} ".json" {"application/json"} 
                        ".jpg" {"image/jpeg"} ".jpeg" {"image/jpeg"} ".png" {"image/png"} ".gif" {"image/gif"} ".webp" {"image/webp"} ".bmp" {"image/bmp"}
                        ".mp4" {"video/mp4"} ".mkv" {"video/mp4"} ".webm" {"video/webm"}
                        ".mp3" {"audio/mpeg"} ".wav" {"audio/wav"} ".ogg" {"audio/ogg"}
                        ".pdf" {"application/pdf"} ".html" {"text/html"} default {"application/octet-stream"} 
                    }
                    $res.ContentType = $mimeType
                    $res.AddHeader("Content-Disposition", "inline; filename=""$fileName""")
                    $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                } catch {
                    $res.StatusCode = 500; $buffer = [System.Text.Encoding]::UTF8.GetBytes("Gagal membaca file, mungkin sedang dibuka di tempat lain."); $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
            } else { 
                $res.StatusCode = 404; $buffer = [System.Text.Encoding]::UTF8.GetBytes("File tidak ditemukan."); $res.OutputStream.Write($buffer, 0, $buffer.Length) 
            }
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT DOWNLOAD ---
        if ($req.Url.AbsolutePath -eq "/download") {
            $pathDownload = $req.QueryString["path"]
            if (Test-Path -LiteralPath $pathDownload -PathType Leaf) { 
                try {
                    $fileBytes = [System.IO.File]::ReadAllBytes($pathDownload)
                    $fileName = (Get-Item -LiteralPath $pathDownload).Name
                    $res.ContentType = "application/octet-stream"
                    $res.AddHeader("Content-Disposition", "attachment; filename=""$fileName""")
                    $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📥 **[ADMIN CRUD]**: $fileName diunduh."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                } catch {
                    $res.StatusCode = 500; $buffer = [System.Text.Encoding]::UTF8.GetBytes("Gagal mengunduh file, mungkin terkunci sistem."); $res.OutputStream.Write($buffer, 0, $buffer.Length)
                }
            } else { 
                $res.StatusCode = 404; $buffer = [System.Text.Encoding]::UTF8.GetBytes("File tidak ditemukan."); $res.OutputStream.Write($buffer, 0, $buffer.Length) 
            }
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT NEW FOLDER ---
        if ($req.Url.AbsolutePath -eq "/newfolder" -and $req.HttpMethod -eq "POST") {
            $reader = New-Object System.IO.StreamReader($req.InputStream); $fName = ($reader.ReadToEnd().Split("=")[1]).Replace("+", " "); 
            if ($fName) { 
                $decodedFName = [Uri]::UnescapeDataString($fName)
                New-Item -Path (Join-Path $currentPath $decodedFName) -ItemType Directory -Force | Out-Null
                try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📁 **[ADMIN CRUD]**: Folder $decodedFName diproses."}|ConvertTo-Json) -ContentType "application/json" } catch {}
            }
            $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($currentPath))&alert=folder_ok")
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING ENDPOINT UPLOAD RAW ---
        if ($req.Url.AbsolutePath -eq "/upload_raw" -and $req.HttpMethod -eq "POST") {
            $targetDir = $req.QueryString["dir"]
            $fName = $req.QueryString["filename"]
            $targetUploadPath = Join-Path $targetDir $fName
            
            if ($global:lockedFiles.ContainsKey($targetUploadPath)) {
                $res.StatusCode = 403; $res.OutputStream.Close(); continue
            }

            try {
                if (Test-Path -LiteralPath $targetUploadPath) {
                    Set-ItemProperty -LiteralPath $targetUploadPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                }
                
                $fs = New-Object System.IO.FileStream($targetUploadPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                try {
                    $buffer = New-Object byte[] 81920
                    while (($read = $req.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $fs.Write($buffer, 0, $read)
                    }
                } finally {
                    $fs.Dispose()
                }
                
                try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📤 **[ADMIN CRUD]**: File $fName diupload."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                $res.StatusCode = 200
                $resBuffer = [System.Text.Encoding]::UTF8.GetBytes("OK")
                $res.OutputStream.Write($resBuffer, 0, $resBuffer.Length)
            } catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match "Access to the path") { $errMsg = "Akses Ditolak sistem Windows! Solusi: Tutup lalu jalankan ulang PowerShell menggunakan mode 'Run as Administrator'." }
                Write-Host "Error Upload Raw: $errMsg" -ForegroundColor Red
                $res.StatusCode = 500
                $errBuffer = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                $res.OutputStream.Write($errBuffer, 0, $errBuffer.Length)
            }
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT UPLOAD KLASIK ---
        if ($req.Url.AbsolutePath -eq "/upload" -and $req.HttpMethod -eq "POST") {
            try {
                $boundary = $req.ContentType.Split("=")[1]; $reader = New-Object System.IO.BinaryReader($req.InputStream); $inputData = $reader.ReadBytes($req.ContentLength64); $content = [System.Text.Encoding]::Default.GetString($inputData); $fName = [regex]::Match($content, 'filename="(.+?)"').Groups[1].Value
                $renameTo = $req.QueryString["renameTo"]; if (-not [string]::IsNullOrWhiteSpace($renameTo)) { $fName = $renameTo }
                if ($fName) { 
                    $targetUploadPath = Join-Path $currentPath $fName
                    if (-not $global:lockedFiles.ContainsKey($targetUploadPath)) {
                        $start = [regex]::Match($content, "(?s).*?Content-Type:.*?\r\n\r\n").Length; $end = $inputData.Length - ([System.Text.Encoding]::Default.GetBytes("--$boundary").Length + 8); 
                        [System.IO.File]::WriteAllBytes($targetUploadPath, $inputData[$start..$end])
                        try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="📤 **[ADMIN CRUD]**: File $fName diupload."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                    }
                }
            } catch {}
            $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($currentPath))&alert=upload_ok")
            $res.OutputStream.Close()
            continue
        }
        
        # --- ROUTING ENDPOINT DELETE ---
        if ($req.Url.AbsolutePath -eq "/delete") {
            $pathDel = $req.QueryString["path"]
            $redir = $req.QueryString["redir"]
            
            if ($global:lockedFiles.ContainsKey($pathDel)) {
                $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=locked_error"); $res.OutputStream.Close(); continue
            }

            if (Test-Path -LiteralPath $pathDel) {
                $name = (Get-Item -LiteralPath $pathDel).Name
                try {
                    Remove-Item -LiteralPath $pathDel -Recurse -Force -ErrorAction Stop
                    try { Invoke-RestMethod -Uri $webhookURL -Method Post -Body (@{content="🗑️ **[ADMIN CRUD]**: $name dihapus."}|ConvertTo-Json) -ContentType "application/json" } catch {}
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=delete_ok")
                } catch {
                    $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))&alert=in_use_error")
                }
            } else {
                $res.StatusCode = 302; $res.AddHeader("Location", "/list?dir=$([Uri]::EscapeDataString($redir))")
            }
            $res.OutputStream.Close()
            continue
        }

        # --- ROUTING UTAMA: ENDPOINT /LIST (GET MEDIA RENDER) ---
        if ($req.Url.AbsolutePath -eq "/list") {
            
            # [PERBAIKAN] Fitur Search menggunakan Where-Object + Regex Escape untuk menghindari crash saat user input simbol `[` atau `]`
            if (-not [string]::IsNullOrWhiteSpace($q)) {
                $items = Get-ChildItem -LiteralPath $currentPath -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($q) } | Select-Object -First 50
            } else { 
                $items = Get-ChildItem -LiteralPath $currentPath -ErrorAction SilentlyContinue 
            }
            
            $existingNamesJson = "[]"
            if ($items) { $existingNamesJson = @($items.Name) | ConvertTo-Json -Compress }
            
            $parentPath = if ($currentPath.Length -gt 3) { (Get-Item -LiteralPath $currentPath).Parent.FullName } else { $currentPath }
            $selAll = if ($t -eq "all" -or [string]::IsNullOrWhiteSpace($t)) { "selected" } else { "" }
            $selFile = if ($t -eq "file") { "selected" } else { "" }
            $selFolder = if ($t -eq "folder") { "selected" } else { "" }

            $currentDirName = if ($currentPath.Length -gt 3) { (Get-Item -LiteralPath $currentPath).Name } else { $currentPath }
            $currentDirNameEscaped = $currentDirName.Replace("\", "\\").Replace("'", "\'")

            $parts = $currentPath.Split('\')
            $accPath = ""; $breadcrumbHtml = ""
            foreach ($p in $parts) {
                if ([string]::IsNullOrWhiteSpace($p)) { continue }
                if ($accPath -eq "") { $accPath = $p + "\" } else { $accPath = Join-Path $accPath $p }
                $escAcc = $([Uri]::EscapeDataString($accPath))
                $breadcrumbHtml += "<a href='/list?dir=$escAcc' class='breadcrumb-link' ondragover='event.preventDefault(); event.stopPropagation(); this.classList.add(""drag-over"")' ondragleave='this.classList.remove(""drag-over"")' ondrop='dropOnBreadcrumb(event, ""$escAcc"", ""$p"")'>$p</a> <span style='color:var(--text-muted); font-size:14px; margin:0 2px;'>/</span> "
            }

            $htmlHeader = @'
<!DOCTYPE html>
<html><head><meta charset='UTF-8'><meta name='viewport' content='width=device-width, initial-scale=1.0'><title>Server File Manager</title>
<script src='https://cdn.jsdelivr.net/npm/sweetalert2@11'></script>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/viewerjs/1.11.6/viewer.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/viewerjs/1.11.6/viewer.min.js"></script>
<script>
    (function() {
        const theme = localStorage.getItem('theme') || 'light';
        if (theme === 'dark') document.documentElement.classList.add('dark-mode');
    })();
</script>
<style>
    /* KONFIGURASI WARNA & GLASSMORPHISM */
    :root { 
        --primary: #3b82f6; --primary-hover: #2563eb; 
        --bg-main: #dbeafe; 
        --card-bg: rgba(255, 255, 255, 0.35); 
        --text-dark: #0f172a; --text-muted: #475569; 
        --border-color: rgba(255, 255, 255, 0.6); 
        --table-row-hover: rgba(255, 255, 255, 0.6); 
        --th-bg: rgba(255, 255, 255, 0.3); 
        --input-bg: rgba(255, 255, 255, 0.5); 
        --shadow: 0 8px 32px 0 rgba(31, 38, 135, 0.07);
    }
    
    html.dark-mode {
        --bg-main: #020617; 
        --card-bg: rgba(17, 24, 39, 0.45); 
        --text-dark: #f8fafc; --text-muted: #94a3b8; 
        --border-color: rgba(255, 255, 255, 0.15); 
        --table-row-hover: rgba(255, 255, 255, 0.08); 
        --th-bg: rgba(0, 0, 0, 0.2); 
        --input-bg: rgba(0, 0, 0, 0.4); 
        --shadow: 0 8px 32px 0 rgba(0, 0, 0, 0.4);
    }

    body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: var(--bg-main); margin: 0; padding: 24px 16px; color: var(--text-dark); transition: background 0.5s, color 0.3s; position: relative; overflow-x: hidden; min-height: 100vh; }
    
    .sky-container { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; z-index: -1; pointer-events: none; overflow: hidden; }
    .theme-overlay { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; pointer-events: none; z-index: 9999; clip-path: circle(0% at 90% 40px); transition: clip-path 0.8s cubic-bezier(0.4, 0, 0.2, 1); }
    .theme-overlay.active { clip-path: circle(150% at 90% 40px); }

    .cloud, .star { position: absolute; background: rgba(255,255,255,0.4); border-radius: 50%; opacity: 0; transition: opacity 0.5s; }
    html.dark-mode .star { opacity: 1; animation: blink var(--duration, 2s) infinite ease-in-out; }
    html:not(.dark-mode) .cloud { opacity: 0.6; animation: float var(--duration, 20s) infinite linear; }
    
    .sun { width: 140px; height: 140px; background: radial-gradient(circle, #ffebb5 0%, #fcd34d 40%, #f59e0b 100%); border-radius: 50%; position: absolute; top: 8%; right: 10%; box-shadow: 0 0 80px 30px rgba(252, 211, 77, 0.6), 0 0 120px 60px rgba(245, 158, 11, 0.3); animation: celestialRise 2s cubic-bezier(0.2, 0.8, 0.2, 1) forwards, floatSun 8s ease-in-out infinite alternate; z-index: 0; }
    .moon { width: 120px; height: 120px; background: radial-gradient(circle at 30% 30%, #f8fafc 0%, #cbd5e1 50%, #94a3b8 100%); border-radius: 50%; position: absolute; top: 12%; right: 10%; box-shadow: 0 0 60px 20px rgba(241, 245, 249, 0.3), inset -10px -10px 20px rgba(0,0,0,0.2); animation: celestialRise 2s cubic-bezier(0.2, 0.8, 0.2, 1) forwards, floatMoon 10s ease-in-out infinite alternate; z-index: 0; overflow: hidden; }
    .moon::after { content: ''; position: absolute; top: 25px; left: 45px; width: 25px; height: 25px; background: rgba(0,0,0,0.1); border-radius: 50%; box-shadow: inset 2px 2px 4px rgba(0,0,0,0.15); }
    .moon::before { content: ''; position: absolute; top: 65px; left: 25px; width: 15px; height: 15px; background: rgba(0,0,0,0.1); border-radius: 50%; box-shadow: inset 1px 1px 3px rgba(0,0,0,0.15); }

    @keyframes blink { 0%, 100% { opacity: 0.2; transform: scale(0.8); } 50% { opacity: 1; transform: scale(1.2); } }
    @keyframes float { from { transform: translateX(-150px); } to { transform: translateX(105vw); } }
    @keyframes celestialRise { from { transform: translateY(150px) scale(0.8); opacity: 0; } to { transform: translateY(0) scale(1); opacity: 1; } }
    @keyframes floatSun { from { transform: translateY(0); } to { transform: translateY(-20px); } }
    @keyframes floatMoon { from { transform: translateY(0); } to { transform: translateY(15px); } }

    .container { max-width: 1400px; margin: auto; background: var(--card-bg); padding: 32px; border-radius: 16px; box-shadow: var(--shadow); position: relative; transition: background 0.5s, color 0.3s, border-color 0.3s; z-index: 1; backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px); border: 1px solid var(--border-color); }
    
    .header-wrapper { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid var(--border-color); padding-bottom: 16px; margin-bottom: 24px; gap: 16px; width: 100%; box-sizing: border-box; }
    .title-container { flex: 1; min-width: 0; display: flex; align-items: center; }
    .breadcrumb-scroll { display: inline-flex; align-items: center; gap: 4px; overflow-x: auto; max-width: 100%; white-space: nowrap; vertical-align: middle; scrollbar-width: none; -ms-overflow-style: none; padding-bottom: 2px; }
    .breadcrumb-scroll::-webkit-scrollbar { display: none; }
    .right-controls { display: flex; align-items: center; gap: 12px; flex-shrink: 0; }
    .theme-toggle-btn { background: var(--input-bg); color: var(--text-dark); border: 1px solid var(--border-color); font-size: 16px; width: 42px; height: 42px; border-radius: 8px; cursor: pointer; display: flex; align-items: center; justify-content: center; transition: all 0.2s ease; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
    .theme-toggle-btn:hover { transform: scale(1.05); background: var(--primary); color: white; border-color: var(--primary); }

    .hamburger-btn { display: none; background: #0f172a; color: white; border: none; font-size: 18px; width: 42px; height: 42px; border-radius: 8px; cursor: pointer; transition: all 0.2s ease; font-weight: 600; text-align: center; line-height: 42px; padding: 0; box-sizing: border-box; }
    html.dark-mode .hamburger-btn { background: #1f2937; color: #f8fafc; border: 1px solid #374151; }
    .hamburger-btn:hover { background: var(--primary); transform: translateY(-1px); color: white; }
    .menu-content-wrapper { display: block !important; }

    body::after { content: ''; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.4); opacity: 0; pointer-events: none; transition: opacity 0.2s ease; z-index: 9998; }
    body.drag-active::after { opacity: 1; }

    .gdrive-indicator { position: fixed; bottom: 40px; left: 50%; transform: translateX(-50%) translateY(150px); background-color: var(--primary); color: white; padding: 16px 45px 20px; border-radius: 35px; display: flex; flex-direction: column; align-items: center; justify-content: center; box-shadow: 0 10px 30px rgba(59,130,246,0.3); opacity: 0; pointer-events: none; transition: transform 0.4s cubic-bezier(0.175, 0.885, 0.32, 1.275), opacity 0.3s ease; z-index: 10000; }
    .gdrive-indicator.active { opacity: 1; transform: translateX(-50%) translateY(0); }
    .gdrive-icon-circle { background-color: var(--primary); color: white; width: 64px; height: 64px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 32px; font-weight: bold; border: 5px solid #fff; }

    .breadcrumb-link { color: var(--primary); text-decoration: none; font-weight: 600; transition: all 0.2s; padding: 4px 8px; border-radius: 6px; }
    .breadcrumb-link:hover { background: rgba(59,130,246,0.2); color: var(--primary-hover); }
    .breadcrumb-link.drag-over { background: var(--primary); color: white !important; }
    
    .stats-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .stat-card { background: var(--input-bg); border: 1px solid var(--border-color); padding: 14px 20px; border-radius: 12px; display: flex; flex-direction: column; justify-content: center; gap: 6px; font-size: 14px; font-weight: 600; color: var(--text-dark); transition: background 0.3s, border-color 0.3s; min-height: 76px; box-sizing: border-box; }
    .stat-val { font-size: 16px; font-weight: 700; color: var(--primary); }
    .pulse-dot { inline-block; width: 8px; height: 8px; background-color: #10b981; border-radius: 50%; display: inline-block; animation: pulse 2s infinite; margin-right: 6px; }
    
    .drive-container { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; margin-bottom: 24px; align-items: stretch; }
    .drive-btn { padding: 14px 20px; border-radius: 12px; text-decoration: none; font-size: 14px; font-weight: 700; border: 1px solid var(--border-color); transition: all 0.2s ease; display: flex; flex-direction: column; justify-content: center; gap: 4px; box-sizing: border-box; min-height: 76px; background: var(--input-bg); color: var(--text-dark); }
    .drive-active { background: rgba(59,130,246,0.15); color: var(--primary); border-color: var(--primary); box-shadow: 0 4px 6px -1px rgba(59,130,246,0.1); }
    .drive-inactive:hover { background: var(--table-row-hover); border-color: var(--text-muted); }
    
    .nav-links { margin-bottom: 24px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .nav-links .btn-nav { background: #64748b !important; color: #ffffff !important; padding: 10px 20px; border-radius: 8px; text-decoration: none; font-size: 14px; font-weight: 600; transition: all 0.2s ease; height: 42px; display: inline-flex; align-items: center; box-sizing: border-box; border: none; cursor: pointer; }
    .nav-links .btn-nav:hover { background: #475569 !important; transform: translateY(-1px); }
    .nav-links .btn-nav-primary { background: var(--primary) !important; color: #ffffff !important; }
    .nav-links .btn-nav-primary:hover { background: var(--primary-hover) !important; }
    .bulk-panel { display: none; background: rgba(249,115,22,0.15); border: 1px solid rgba(249,115,22,0.3); padding: 0 16px; border-radius: 8px; gap: 12px; align-items: center; font-size: 13px; font-weight: 700; color: #f97316; height: 42px; box-sizing: border-box; }

    .toolbar { display: flex; background: transparent; padding: 0; border: none; margin-bottom: 24px; align-items: center; flex-wrap: wrap; gap: 16px; width: 100%; box-sizing: border-box; }
    .toolbar form { margin: 0; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; height: 42px; box-sizing: border-box; }
    .toolbar input[type='text'], .toolbar input[type='search'], .toolbar select { height: 42px !important; line-height: 42px; padding: 0 16px; border: 1px solid var(--border-color); background: var(--input-bg); color: var(--text-dark); border-radius: 8px; font-size: 14px; outline: none; box-sizing: border-box; margin: 0; display: inline-flex; align-items: center; justify-content: center; font-family: inherit; transition: all 0.2s; }
    .toolbar button.btn-submit { height: 42px !important; line-height: 42px; padding: 0 16px; border: none !important; border-radius: 8px; font-size: 14px; outline: none; box-sizing: border-box; margin: 0; display: inline-flex; align-items: center; justify-content: center; font-family: inherit; transition: all 0.2s; font-weight: 600; cursor: pointer; color: #ffffff !important; }
    .toolbar input[type='text']:focus, .toolbar input[type='search']:focus, .toolbar select:focus { border-color: var(--primary); box-shadow: 0 0 0 3px rgba(59,130,246,0.3); }
    
    .btn-search { background: #3b82f6 !important; } .btn-search:hover { background: #2563eb !important; }
    .btn-create { background: #10b981 !important; } .btn-create:hover { background: #059669 !important; }
    .btn-upload { background: #8b5cf6; font-weight: 600; color: #fff; border: none; cursor: pointer; height: 42px; padding: 0 16px; border-radius: 8px; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; } .btn-upload:hover { background: #7c3aed; }
    
    .separator { width: 1px; height: 24px; background: var(--border-color); align-self: center; }
    .dropzone { border: 2px dashed var(--text-muted); background: var(--input-bg); color: var(--text-muted); border-radius: 8px; height: 42px; padding: 0 20px; display: flex; align-items: center; justify-content: center; gap: 12px; transition: all 0.2s; cursor: pointer; flex-grow: 1; box-sizing: border-box; font-size: 14px; font-weight: 600; }
    .dropzone:hover { border-color: var(--primary); color: var(--text-dark); background: var(--table-row-hover); }
    .dropzone.dragover { background: rgba(59,130,246,0.15); border-color: var(--primary); color: var(--primary); }
    
    .table-responsive { width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; background: transparent; border: 1px solid var(--border-color); border-radius: 12px; box-shadow: var(--shadow); transition: background 0.3s, border-color 0.3s; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; min-width: 1000px; }
    th, td { padding: 14px 18px; text-align: left; border-bottom: 1px solid var(--border-color); vertical-align: middle; transition: background 0.2s, border-color 0.2s; }
    th { background: var(--th-bg); color: var(--text-dark); font-weight: 600; font-size: 13px; text-transform: uppercase; letter-spacing: 0.5px; user-select: none; transition: background-color 0.2s ease; position: relative; }
    th.sortable:hover { background-color: var(--table-row-hover); cursor: pointer; }
    .sort-icon { font-size: 11px; margin-left: 6px; color: var(--text-muted); }
    tr { transition: background-color 0.2s; }
    tr:hover { background: var(--table-row-hover); }
    .row-drag-over td { background-color: rgba(59,130,246,0.2) !important; border-top: 2px dashed var(--primary); border-bottom: 2px dashed var(--primary); }
    
    td a.file-link { color: var(--text-dark); text-decoration: none; font-weight: 600; }
    td a.file-link:hover { color: var(--primary); }
    .type-badge { font-size: 10px; padding: 4px 8px; border-radius: 6px; font-weight: 700; color: white; display: inline-block; text-align: center; letter-spacing: 0.3px; }
    .type-folder { background: #f59e0b; } .type-file { background: #64748b; }
    .action-btn { padding: 6px 12px; border-radius: 6px; font-size: 12px; color: #fff !important; text-decoration: none !important; margin-right: 4px; display: inline-flex; align-items: center; font-weight: 600; border: none; cursor: pointer; transition: opacity 0.15s; }
    .action-btn:hover { opacity: 0.9; }
    
    textarea.editor-box { width:100%; height:60vh; font-family:monospace; padding:12px; box-sizing:border-box; border-radius:8px; border:1px solid var(--border-color); background:var(--input-bg); color:var(--text-dark); resize:vertical; font-size:14px; line-height:1.5; }
    textarea.editor-box:focus { border-color: var(--primary); outline:none; box-shadow: 0 0 0 3px rgba(59,130,246,0.3); }

    .footer { text-align: center; margin-top: 40px; padding-top: 24px; border-top: 1px solid var(--border-color); color: var(--text-muted); font-size: 13px; font-weight: 600; }
    .viewer-print::before { content: '🖨️'; font-size: 16px; display: flex; align-items: center; justify-content: center; width: 100%; height: 100%; color: white; }

    @media (max-width: 992px) {
        .hamburger-btn { display: block; }
        .menu-content-wrapper { display: none !important; flex-direction: column; gap: 16px; background: var(--card-bg); backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px); padding: 20px; border-radius: 12px; border: 1px solid var(--border-color); margin-bottom: 24px; }
        .menu-content-wrapper.open { display: flex !important; }
        .stats-bar { grid-template-columns: 1fr; gap: 12px; }
        .drive-container { grid-template-columns: 1fr; gap: 12px; }
        .nav-links { flex-direction: column; align-items: stretch; gap: 10px; }
        .nav-links a { justify-content: center; width: 100%; }
        .bulk-panel { width: 100%; justify-content: center; }
        .toolbar { flex-direction: column; align-items: stretch; gap: 16px; width: 100%; }
        .toolbar form { height: auto; flex-direction: column; align-items: stretch; gap: 10px; width: 100%; }
        .toolbar input[type='text'], .toolbar input[type='search'], .toolbar select, .toolbar button.btn-submit { width: 100% !important; }
        .separator { display: none; }
        .dropzone { width: 100%; }
    }
</style>

<script>
    var existingItems = PLACEHOLDER_EXISTING_JSON;
    var currentDirPath = decodeURIComponent("PLACEHOLDER_CURRENT_DIR_PATH");
    var defaultFolderName = "PLACEHOLDER_DEFAULT_FOLDER_NAME";

    function toggleTheme() {
        const root = document.documentElement;
        const btnIcon = document.getElementById('theme-icon');
        const overlay = document.getElementById('themeOverlay');
        
        const isDark = root.classList.contains('dark-mode');
        overlay.style.background = isDark ? '#dbeafe' : '#020617';
        overlay.classList.add('active');
        
        setTimeout(() => {
            if (isDark) {
                root.classList.remove('dark-mode');
                localStorage.setItem('theme', 'light');
                btnIcon.innerText = '🌙';
            } else {
                root.classList.add('dark-mode');
                localStorage.setItem('theme', 'dark');
                btnIcon.innerText = '☀️';
            }
            generateSkyEffects(); 
        }, 400);

        setTimeout(() => { overlay.classList.remove('active'); }, 850);
    }

    function generateSkyEffects() {
        const sky = document.getElementById('skyCanvas');
        if (!sky) return;
        sky.innerHTML = '';
        
        const isDark = document.documentElement.classList.contains('dark-mode');
        
        const celestial = document.createElement('div');
        if (isDark) {
            celestial.className = 'moon';
            const crater1 = document.createElement('div');
            const crater2 = document.createElement('div');
            celestial.appendChild(crater1);
            celestial.appendChild(crater2);
        } else {
            celestial.className = 'sun';
        }
        sky.appendChild(celestial);

        const maxParticles = isDark ? 60 : 8;
        for(let i = 0; i < maxParticles; i++) {
            const el = document.createElement('div');
            el.className = isDark ? 'star' : 'cloud';
            el.style.left = Math.random() * 100 + 'vw';
            el.style.top = Math.random() * (isDark ? 80 : 30) + 'vh';
            
            if(isDark) {
                const size = Math.random() * 3 + 1;
                el.style.width = size + 'px'; el.style.height = size + 'px';
                el.style.setProperty('--duration', (Math.random() * 3 + 1) + 's');
                el.style.background = '#ffffff';
            } else {
                const w = Math.random() * 120 + 60;
                el.style.width = w + 'px'; el.style.height = (w * 0.4) + 'px';
                el.style.setProperty('--duration', (Math.random() * 30 + 20) + 's');
                el.style.background = '#ffffff';
                el.style.borderRadius = '100px';
                el.style.filter = 'blur(4px)';
            }
            sky.appendChild(el);
        }
    }

    function toggleMobileMenu() {
        const menu = document.getElementById('menuWrapper');
        if(menu.style.display === 'flex' || menu.classList.contains('open')) {
            menu.style.setProperty('display', 'none', 'important');
            menu.classList.remove('open');
        } else {
            menu.style.setProperty('display', 'flex', 'important');
            menu.classList.add('open');
        }
    }

    window.addEventListener('DOMContentLoaded', () => {
        generateSkyEffects();
        
        const currentTheme = localStorage.getItem('theme') || 'light';
        document.getElementById('theme-icon').innerText = currentTheme === 'dark' ? '☀️' : '🌙';

        const urlParams = new URLSearchParams(window.location.search);
        const alertType = urlParams.get('alert');
        if (alertType) {
            if (alertType === 'upload_ok') Swal.fire('Berhasil!', 'File berhasil diupload ke server.', 'success');
            else if (alertType === 'delete_ok') Swal.fire('Terhapus!', 'Item dihapus.', 'success');
            else if (alertType === 'folder_ok') Swal.fire('Selesai!', 'Folder dibuat.', 'success');
            else if (alertType === 'zip_ok') Swal.fire('Sukses!', 'Folder berhasil dikompres menjadi ZIP.', 'success');
            else if (alertType === 'extract_ok') Swal.fire('Sukses!', 'File berhasil diekstrak.', 'success');
            else if (alertType === 'move_ok') Swal.fire('Sukses!', 'Item berhasil dipindahkan.', 'success');
            else if (alertType === 'rename_ok') Swal.fire('Sukses!', 'Nama item berhasil diubah.', 'success');
            else if (alertType === 'in_use_error') Swal.fire('Gagal!', 'File/folder tidak bisa dihapus atau diubah karena sedang terbuka di komputer lain!', 'error');
            else if (alertType === 'lock_ok') Swal.fire('Terkunci!', 'File berhasil dikunci untuk mencegah override (ditimpa user lain).', 'success');
            else if (alertType === 'unlock_ok') Swal.fire('Terbuka!', 'Kunci file telah dilepas.', 'success');
            else if (alertType === 'locked_error') Swal.fire('Akses Ditolak!', 'Gagal. File ini sedang DIKUNCI oleh user lain!', 'error');
            
            window.history.replaceState({}, document.title, '/list?dir=' + encodeURIComponent(currentDirPath));
        }

        function loadServerStats() {
            fetch('/stats').then(response => response.json()).then(data => {
                document.getElementById('cpu-stat').innerText = data.cpu + '%';
                document.getElementById('ram-stat').innerText = data.usedRam + ' GB / ' + data.totalRam + ' GB (' + data.ramPct + '%)';
                if (document.getElementById('ip-stat')) { document.getElementById('ip-stat').innerText = data.serverIp; }
                document.getElementById('user-stat').innerHTML = "<span class='pulse-dot'></span>" + data.activeUsers + ' IP Aktif';
            }).catch(e => { 
                document.getElementById('cpu-stat').innerText = 'Timeout';
                document.getElementById('user-stat').innerText = '-';
            });
        }
        loadServerStats(); setInterval(loadServerStats, 5000); 

        let dragTimer;
        const dropIndicator = document.getElementById('gdrive-drop-indicator');
        const dropFolderName = document.getElementById('gdrive-drop-folder');

        document.addEventListener('dragover', function(e) {
            e.preventDefault();
            
            // [PERBAIKAN] Memastikan tipe drag yang tepat agar tidak tertukar dengan file OS
            let isInternalMove = false;
            if (e.dataTransfer.types) {
                for (let i = 0; i < e.dataTransfer.types.length; i++) {
                    if (e.dataTransfer.types[i] === 'application/x-bitek-path') isInternalMove = true;
                }
            }

            if (e.dataTransfer.files && !isInternalMove) {
                document.body.classList.add('drag-active'); dropIndicator.classList.add('active');
                let row = e.target.closest('tr[data-foldername]');
                if(row) { dropFolderName.innerText = row.getAttribute('data-foldername'); } 
                else { dropFolderName.innerText = defaultFolderName; }
                clearTimeout(dragTimer);
            }
        });

        document.addEventListener('dragleave', function(e) {
            clearTimeout(dragTimer);
            dragTimer = setTimeout(() => { document.body.classList.remove('drag-active'); dropIndicator.classList.remove('active'); }, 100);
        });

        document.addEventListener('drop', async function(e) {
            e.preventDefault();
            document.body.classList.remove('drag-active'); dropIndicator.classList.remove('active');
            
            let isInternalMove = false;
            if (e.dataTransfer.types) {
                for (let i = 0; i < e.dataTransfer.types.length; i++) {
                    if (e.dataTransfer.types[i] === 'application/x-bitek-path') isInternalMove = true;
                }
            }

            if(e.dataTransfer.files && e.dataTransfer.files.length > 0 && !isInternalMove) {
                var files = e.dataTransfer.files;
                Swal.fire({
                    title: 'Upload ' + files.length + ' File?', text: 'Upload ke direktori saat ini: ' + defaultFolderName,
                    icon: 'info', showCancelButton: true, confirmButtonColor: '#3498db', confirmButtonText: 'Ya, Upload'
                }).then(async (res) => {
                    if(res.isConfirmed) {
                        Swal.fire({ title: 'Mengupload...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
                        for(let i=0; i<files.length; i++) {
                            let file = files[i];
                            let resFetch = await fetch('/upload_raw?dir=' + encodeURIComponent(currentDirPath) + '&filename=' + encodeURIComponent(file.name), { method: 'POST', body: file, headers: { 'Content-Type': 'application/octet-stream' } });
                            if (!resFetch.ok) {
                                let errMsg = await resFetch.text();
                                Swal.fire('Gagal!', 'File ' + file.name + ' gagal diupload. \n\n' + errMsg, 'error'); return;
                            }
                        }
                        window.location.href = '/list?dir=' + encodeURIComponent(currentDirPath) + '&alert=upload_ok';
                    }
                });
            }
        });
        
        const dropzone = document.getElementById('dropzone'); const fileInput = document.getElementById('fileinput');
        dropzone.addEventListener('dragover', (e) => { e.preventDefault(); e.stopPropagation(); dropzone.classList.add('dragover'); });
        dropzone.addEventListener('dragleave', () => { dropzone.classList.remove('dragover'); });
        dropzone.addEventListener('drop', (e) => {
            e.preventDefault(); e.stopPropagation(); dropzone.classList.remove('dragover');
            document.body.classList.remove('drag-active'); dropIndicator.classList.remove('active');
            if(e.dataTransfer.files.length > 0) { fileInput.files = e.dataTransfer.files; updateFileText(); }
        });
    });

    function validateSearch(e) {
        var searchInput = document.getElementById('searchinput').value.trim();
        if (searchInput === '') { e.preventDefault(); return Swal.fire('Peringatan!', 'Harap masukan kata kunci yang ingin di cari.', 'warning'); }
    }

    function validateFolder(e) {
        e.preventDefault();
        var input = document.getElementById('foldername').value.trim();
        if (input === '') return Swal.fire('Kosong!', 'Masukan nama folder.', 'warning');
        if (existingItems.includes(input)) Swal.fire('Sudah Ada', 'Nama sudah digunakan.', 'warning');
        else document.getElementById('form-folder').submit();
    }

    function updateFileText() {
        var fileInput = document.getElementById('fileinput'); var dropText = document.getElementById('drop-text'); var btnUpload = document.getElementById('btn-upload-all');
        if (fileInput.files.length > 0) {
            var fileNames = fileInput.files.length === 1 ? fileInput.files[0].name : fileInput.files.length + ' file terpilih';
            dropText.innerHTML = '<b>📄 ' + fileNames + '</b> <a href="#" onclick="clearFiles(event)" style="color:#e74c3c; margin-left:15px; text-decoration:none; font-weight:bold; padding:4px 8px; background:#fadbd8; border-radius:4px;">✖ Batal</a>';
            btnUpload.style.display = 'block'; btnUpload.disabled = false;
        }
    }

    function clearFiles(e) {
        e.preventDefault(); e.stopPropagation();
        document.getElementById('fileinput').value = ''; 
        document.getElementById('drop-text').innerHTML = '<b>📥 Klik atau drag n drop file disini</b>'; 
        document.getElementById('btn-upload-all').style.display = 'none';
    }

    async function uploadMultiple() {
        var fileInput = document.getElementById('fileinput'); var files = fileInput.files;
        if(files.length === 0) return Swal.fire('Kosong!', 'Pilih file terlebih dahulu.', 'warning');
        const btnUpload = document.getElementById('btn-upload-all');
        btnUpload.disabled = true;
        Swal.fire({
            title: 'Konfirmasi Upload', text: 'Yakin ingin menambahkan file ke folder ini?', icon: 'question', showCancelButton: true, confirmButtonColor: '#3498db', confirmButtonText: 'Ya, Upload'
        }).then(async (res) => {
            if(res.isConfirmed) {
                Swal.fire({ title: 'Mengupload ' + files.length + ' file...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
                for(let i=0; i<files.length; i++) {
                    let file = files[i];
                    let resFetch = await fetch('/upload_raw?dir=' + encodeURIComponent(currentDirPath) + '&filename=' + encodeURIComponent(file.name), { method: 'POST', body: file, headers: { 'Content-Type': 'application/octet-stream' } });
                    if (!resFetch.ok) {
                        let errMsg = await resFetch.text();
                        Swal.fire('Gagal!', 'File ' + file.name + ' gagal diupload. \n\n' + errMsg, 'error'); btnUpload.disabled = false; return;
                    }
                }
                window.location.href = '/list?dir=' + encodeURIComponent(currentDirPath) + '&alert=upload_ok';
            } else {
                btnUpload.disabled = false;
            }
        });
    }

    function confirmAction(e, url, msg) {
        e.preventDefault(); Swal.fire({ title: 'Konfirmasi', text: msg, icon: 'warning', showCancelButton: true, confirmButtonColor: '#e74c3c' }).then((res) => { if(res.isConfirmed) window.location.href = url; });
    }
    
    function copyLink(e, relativeUrl) {
        e.preventDefault(); e.stopPropagation();
        const url = window.location.origin + relativeUrl;
        navigator.clipboard.writeText(url).then(() => {
            Swal.fire({ toast: true, position: 'top-end', icon: 'success', title: 'Tautan disalin ke Clipboard!', showConfirmButton: false, timer: 2000 });
        }).catch(() => {
            Swal.fire('Gagal', 'Sistem tidak dapat menyalin tautan.', 'error');
        });
    }
    
    function showPreview(e, previewUrl, printUrl, fileName, ext) {
        e.preventDefault();
        
        const imgExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
        if (imgExts.includes(ext)) {
            let image = new Image();
            image.src = previewUrl;
            image.alt = fileName;
            
            let viewer = new Viewer(image, {
                hidden: function () { viewer.destroy(); },
                toolbar: {
                    zoomIn: 1, zoomOut: 1, oneToOne: 1, reset: 1, rotateLeft: 1, rotateRight: 1, flipHorizontal: 1, flipVertical: 1,
                    print: {
                        show: 1, size: 'large', title: 'Print Gambar',
                        click: function() { window.open(printUrl, '_blank'); }
                    }
                }
            });
            viewer.show();
            return;
        }

        let htmlContent = '';
        if (['.mp4', '.mkv', '.webm'].includes(ext)) {
            htmlContent = '<video controls autoplay style="width:100%; max-height:70vh; border-radius:8px;"><source src="' + previewUrl + '" type="video/mp4">Browser Anda tidak mendukung preview video.</video>';
        } else if (['.mp3', '.wav', '.ogg'].includes(ext)) {
            htmlContent = '<div style="padding:30px;">🎵 <b>Memutar:</b> ' + fileName + '<br><br><audio controls autoplay style="width:100%;"><source src="' + previewUrl + '" type="audio/mpeg">Browser Anda tidak mendukung preview audio.</audio></div>';
        } else {
            htmlContent = '<iframe src="' + previewUrl + '" style="width:100%; height:70vh; border:none; border-radius:8px;"></iframe>';
        }
        Swal.fire({ title: fileName, html: htmlContent, width: ['.mp3', '.wav'].includes(ext) ? '500px' : '85%', showCloseButton: true, showConfirmButton: !['.mp4', '.mkv', '.webm', '.mp3', '.wav'].includes(ext), confirmButtonText: '🖨️ Print', confirmButtonColor: '#e67e22', showCancelButton: true, cancelButtonText: 'Tutup' }).then((r) => { if (r.isConfirmed) window.open(printUrl, '_blank'); });
    }

    async function editFile(e, pathStr, fileName) {
        e.preventDefault();
        Swal.fire({ title: 'Memuat...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
        try {
            let res = await fetch('/preview?path=' + encodeURIComponent(pathStr));
            if (!res.ok) throw new Error('Gagal memuat file dari server');
            let text = await res.text();
            
            let safeText = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
            
            Swal.fire({
                title: 'Edit Teks: ' + fileName,
                html: '<textarea id="edit-textarea" class="editor-box" spellcheck="false">' + safeText + '</textarea>',
                width: '80%',
                showCancelButton: true,
                confirmButtonText: '💾 Simpan',
                confirmButtonColor: '#10b981',
                cancelButtonText: 'Batal',
                preConfirm: () => {
                    return document.getElementById('edit-textarea').value;
                }
            }).then(async (result) => {
                if (result.isConfirmed) {
                    Swal.fire({ title: 'Menyimpan...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
                    let saveRes = await fetch('/save-text?path=' + encodeURIComponent(pathStr), { method: 'POST', body: result.value });
                    if (saveRes.ok) {
                        Swal.fire('Tersimpan!', 'Perubahan pada file teks berhasil disimpan ke server.', 'success');
                    } else if (saveRes.status === 403) {
                        Swal.fire('Akses Ditolak!', 'File ini sedang dikunci oleh user lain. Hubungi pemilik kunci.', 'error');
                    } else {
                        Swal.fire('Gagal!', 'Terjadi kesalahan saat menyimpan file.', 'error');
                    }
                }
            });
        } catch (err) {
            Swal.fire('Error', err.message, 'error');
        }
    }

    function showRenameModal(e, itemPath, itemName) {
        e.preventDefault();
        Swal.fire({
            title: 'Ubah Nama Item',
            input: 'text',
            inputValue: itemName,
            showCancelButton: true,
            confirmButtonText: 'Simpan',
            confirmButtonColor: '#2ecc71',
            preConfirm: (newName) => {
                if (!newName || newName.trim() === '') { Swal.showValidationMessage('Nama tidak boleh kosong!'); }
                return newName;
            }
        }).then((result) => {
            if (result.isConfirmed) {
                window.location.href = '/rename?path=' + encodeURIComponent(itemPath) + '&newName=' + encodeURIComponent(result.value) + '&redir=' + encodeURIComponent(currentDirPath);
            }
        });
    }

    function toggleSelectAll(master) {
        const checkboxes = document.querySelectorAll('.bulk-checkbox');
        checkboxes.forEach(cb => cb.checked = master.checked);
        updateBulkPanelVisibility();
    }

    function updateBulkPanelVisibility() {
        const checkedCount = document.querySelectorAll('.bulk-checkbox:checked').length;
        const panel = document.getElementById('bulk-panel');
        const countSpan = document.getElementById('bulk-count');
        if (checkedCount >= 2) {
            panel.style.display = 'flex';
            countSpan.innerText = checkedCount + ' item terpilih';
        } else {
            panel.style.display = 'none';
        }
    }

    function getSelectedPaths() {
        const checked = document.querySelectorAll('.bulk-checkbox:checked');
        return Array.from(checked).map(cb => decodeURIComponent(cb.value));
    }

    function bulkDelete() {
        const paths = getSelectedPaths();
        Swal.fire({
            title: 'Hapus Massal?',
            text: 'Yakin ingin menghapus permanen ' + paths.length + ' item yang dipilih?',
            icon: 'warning',
            showCancelButton: true,
            confirmButtonColor: '#e74c3c',
            confirmButtonText: 'Ya, Hapus Semua'
        }).then((res) => {
            if (res.isConfirmed) {
                Swal.fire({ title: 'Menghapus...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
                fetch('/bulk-delete?dir=' + encodeURIComponent(currentDirPath), {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ paths: paths })
                }).then(async (response) => {
                    if (response.status === 409) {
                        Swal.fire('Gagal Menghapus!', 'Beberapa file/folder gagal dihapus karena sedang terbuka di user lain!', 'error');
                    } else if (response.ok) {
                        Swal.fire('Terhapus!', 'Data sudah terhapus.', 'success').then(() => { window.location.reload(); });
                    } else {
                        Swal.fire('Error', 'Kesalahan pada server.', 'error');
                    }
                });
            }
        });
    }

    function bulkDownload() {
        const paths = getSelectedPaths();
        Swal.fire({
            title: 'Download Massal?',
            text: paths.length + ' item akan digabung menjadi file ZIP sebelum diunduh.',
            icon: 'question',
            showCancelButton: true,
            confirmButtonColor: '#27ae60',
            confirmButtonText: 'Ya, Download'
        }).then((res) => {
            if (res.isConfirmed) {
                Swal.fire({ title: 'Menyiapkan arsip ZIP...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
                let formData = new URLSearchParams();
                formData.append('paths', paths.join('|'));
                
                fetch('/bulk-download?dir=' + encodeURIComponent(currentDirPath), {
                    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: formData.toString()
                }).then(async res => {
                    if (res.ok) {
                        let warning = res.headers.get('X-Download-Warning');
                        let blob = await res.blob();
                        let url = window.URL.createObjectURL(blob);
                        let a = document.createElement('a');
                        a.href = url; a.download = 'bulk_download.zip'; document.body.appendChild(a); a.click(); a.remove(); window.URL.revokeObjectURL(url);
                        
                        if (warning === 'empty_skipped') {
                            Swal.fire('Berhasil dengan Peringatan', 'Hanya mengunduh folder yang ada isinya saja. Folder yang kosong tidak bisa didownload.', 'info');
                        } else {
                            Swal.fire('Sukses!', 'File massal berhasil diunduh.', 'success');
                        }
                    } else {
                        let text = await res.text();
                        Swal.fire('Gagal', text || 'Semua folder yang dipilih kosong, tidak ada yang bisa diunduh.', 'error');
                    }
                }).catch(err => { Swal.fire('Error', 'Koneksi terputus dari server.', 'error'); });
            }
        });
    }

    // [PERBAIKAN] Menggunakan identifier spesifik 'application/x-bitek-path' untuk menghindari error perpindahan drag drop file OS
    function dragStartRow(e, srcPath) { e.dataTransfer.setData('application/x-bitek-path', srcPath); }
    function dragOverRow(e) { e.preventDefault(); e.currentTarget.classList.add('row-drag-over'); }
    function dragEnterRow(e) { e.preventDefault(); }
    function dragLeaveRow(e) { e.preventDefault(); e.currentTarget.classList.remove('row-drag-over'); }
    
    function dropOnRow(e, destPath, folderName) {
        e.preventDefault(); e.stopPropagation(); 
        e.currentTarget.classList.remove('row-drag-over'); document.body.classList.remove('drag-active'); document.getElementById('gdrive-drop-indicator').classList.remove('active');
        const files = e.dataTransfer.files; 
        const rawSrcPath = e.dataTransfer.getData('application/x-bitek-path');
        
        const decodedDestPath = decodeURIComponent(destPath);
        const decodedSrcPath = rawSrcPath ? decodeURIComponent(rawSrcPath) : '';

        let isInternalMove = false;
        if (e.dataTransfer.types) {
            for (let i = 0; i < e.dataTransfer.types.length; i++) {
                if (e.dataTransfer.types[i] === 'application/x-bitek-path') isInternalMove = true;
            }
        }

        if (files && files.length > 0 && !isInternalMove) {
            Swal.fire({ title: 'Upload Spesifik ke Folder?', text: 'Upload file ke dalam folder: ' + folderName, icon: 'question', showCancelButton: true, confirmButtonColor: '#3498db', confirmButtonText: 'Ya, Upload' }).then(async (res) => {
                if (res.isConfirmed) {
                    Swal.fire({ title: 'Mengupload...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }});
                    for(let i=0; i<files.length; i++) { 
                        let file = files[i];
                        let resFetch = await fetch('/upload_raw?dir=' + encodeURIComponent(decodedDestPath) + '&filename=' + encodeURIComponent(file.name), { method: 'POST', body: file, headers: { 'Content-Type': 'application/octet-stream' } });
                        if (!resFetch.ok) { 
                            let errMsg = await resFetch.text();
                            Swal.fire('Gagal!', 'File ' + file.name + ' gagal diupload. \n\n' + errMsg, 'error'); return; 
                        }
                    }
                    window.location.reload();
                }
            });
        } else if (decodedSrcPath) {
            if (decodedSrcPath === decodedDestPath) return; 
            Swal.fire({ title: 'Pindahkan Item?', text: 'Memindahkan item ke folder: ' + folderName, icon: 'warning', showCancelButton: true, confirmButtonColor: '#e67e22', confirmButtonText: 'Ya, Pindahkan' }).then(async (res) => {
                if (res.isConfirmed) { 
                    Swal.fire({ title: 'Memindahkan...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }}); 
                    let moveRes = await fetch('/move?src=' + encodeURIComponent(decodedSrcPath) + '&dest=' + encodeURIComponent(decodedDestPath));
                    if(!moveRes.ok) { let msg = await moveRes.text(); Swal.fire('Gagal!', msg, 'error'); } else { window.location.reload(); }
                }
            });
        }
    }
    
    function dropOnBreadcrumb(e, destPath, folderName) {
        e.preventDefault(); e.stopPropagation(); e.currentTarget.classList.remove('drag-over'); document.body.classList.remove('drag-active'); document.getElementById('gdrive-drop-indicator').classList.remove('active');
        const files = e.dataTransfer.files; 
        const rawSrcPath = e.dataTransfer.getData('application/x-bitek-path');
        
        const decodedDestPath = decodeURIComponent(destPath);
        const decodedSrcPath = rawSrcPath ? decodeURIComponent(rawSrcPath) : '';

        let isInternalMove = false;
        if (e.dataTransfer.types) {
            for (let i = 0; i < e.dataTransfer.types.length; i++) {
                if (e.dataTransfer.types[i] === 'application/x-bitek-path') isInternalMove = true;
            }
        }

        if (files && files.length > 0 && !isInternalMove) {
            Swal.fire({ title: 'Upload ke Parent Folder?', text: 'Upload file langsung ke folder: ' + folderName, icon: 'question', showCancelButton: true, confirmButtonColor: '#3498db', confirmButtonText: 'Ya, Upload' }).then(async (res) => {
                if (res.isConfirmed) { 
                    Swal.fire({ title: 'Mengupload...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }}); 
                    for(let i=0; i<files.length; i++) { 
                        let file = files[i];
                        let resFetch = await fetch('/upload_raw?dir=' + encodeURIComponent(decodedDestPath) + '&filename=' + encodeURIComponent(file.name), { method: 'POST', body: file, headers: { 'Content-Type': 'application/octet-stream' } });
                        if (!resFetch.ok) { 
                            let errMsg = await resFetch.text();
                            Swal.fire('Gagal!', 'File ' + file.name + ' gagal diupload. \n\n' + errMsg, 'error'); return; 
                        }
                    } 
                    window.location.reload(); 
                }
            });
        } else if (decodedSrcPath) {
            if (decodedSrcPath === decodedDestPath) return; 
            Swal.fire({ title: 'Pindahkan ke Atas?', text: 'Pindahkan item ini ke folder: ' + folderName, icon: 'warning', showCancelButton: true, confirmButtonColor: '#e67e22', confirmButtonText: 'Ya, Pindahkan' }).then(async (res) => {
                if (res.isConfirmed) { 
                    Swal.fire({ title: 'Memindahkan...', allowOutsideClick: false, didOpen: () => { Swal.showLoading() }}); 
                    let moveRes = await fetch('/move?src=' + encodeURIComponent(decodedSrcPath) + '&dest=' + encodeURIComponent(decodedDestPath)); 
                    if(!moveRes.ok) { let msg = await moveRes.text(); Swal.fire('Gagal!', msg, 'error'); } else { window.location.reload(); }
                }
            });
        }
    }

    var sortDirection = {};
    function sortTable(n, type) {
        var table, rows, switching, i, x, y, shouldSwitch, dir, switchcount = 0;
        table = document.getElementById('fileTable');
        switching = true;
        
        dir = sortDirection[n] === 'asc' ? 'desc' : 'asc';
        sortDirection[n] = dir;

        var headers = table.getElementsByTagName('TH');
        for (let j = 1; j < headers.length - 1; j++) {
            let baseText = headers[j].innerHTML.replace(/<span.*span>/g, '');
            headers[j].innerHTML = baseText + '<span class="sort-icon">↕️</span>';
        }

        while (switching) {
            switching = false;
            rows = table.rows;
            
            for (i = 1; i < (rows.length - 1); i++) {
                if(rows[i].cells.length < 6) continue;

                shouldSwitch = false;
                
                x = rows[i].getElementsByTagName('TD')[n];
                y = rows[i + 1].getElementsByTagName('TD')[n];
                
                let valX = x.innerText.toLowerCase().trim();
                let valY = y.innerText.toLowerCase().trim();

                if (type === 'date') {
                    valX = new Date(valX).getTime() || 0;
                    valY = new Date(valY).getTime() || 0;
                }
                if (type === 'size') {
                    valX = parseFloat(x.getAttribute('data-rawsize')) || 0;
                    valY = parseFloat(y.getAttribute('data-rawsize')) || 0;
                }

                if (dir === 'asc') {
                    if (valX > valY) { shouldSwitch = true; break; }
                } else if (dir === 'desc') {
                    if (valX < valY) { shouldSwitch = true; break; }
                }
            }
            if (shouldSwitch) {
                rows[i].parentNode.insertBefore(rows[i + 1], rows[i]);
                switching = true;
                switchcount++;
            }
        }
        
        let activeIcon = dir === 'asc' ? '🔽' : '🔼';
        let currentText = headers[n].innerHTML.replace(/<span.*span>/g, '');
        headers[n].innerHTML = currentText + '<span class="sort-icon">' + activeIcon + '</span>';
    }
</script>
</head><body>

<div id="skyCanvas" class="sky-container"></div>
<div id="themeOverlay" class="theme-overlay"></div>

<div class='container'>
'@
            
            $html = $htmlHeader.Replace("PLACEHOLDER_EXISTING_JSON", $existingNamesJson)
            $html = $html.Replace("PLACEHOLDER_CURRENT_DIR_PATH", $([Uri]::EscapeDataString($currentPath)))
            $html = $html.Replace("PLACEHOLDER_DEFAULT_FOLDER_NAME", $currentDirNameEscaped)
            $html = $html.Replace("PLACEHOLDER_DIR_NAME", $currentDirName)

            $html += "<div class='header-wrapper'>"
            $html += "    <div class='title-container'>"
            $html += "        <h2>🗄️ <div class='breadcrumb-scroll'>$breadcrumbHtml</div></h2>"
            $html += "    </div>"
            $html += "    <div class='right-controls'>"
            $html += "        <button id='themeToggle' class='theme-toggle-btn' onclick='toggleTheme()' title='Ganti Tema'><span id='theme-icon'>🌙</span></button>"
            $html += "        <button class='hamburger-btn' onclick='toggleMobileMenu()'>☰</button>"
            $html += "    </div>"
            $html += "</div>"
            
            $html += "<div id='menuWrapper' class='menu-content-wrapper'>"
            
            $html += "  <div class='stats-bar'>"
            $html += "     <div class='stat-card'><span>🏠 IP Local Server</span><span id='ip-stat' class='stat-val'>Mengambil data...</span></div>"
            $html += "     <div class='stat-card'><span>💻 Kinerja CPU</span><span id='cpu-stat' class='stat-val'>Mengambil data...</span></div>"
            $html += "     <div class='stat-card'><span>🧠 Konsumsi RAM Fisik</span><span id='ram-stat' class='stat-val'>Mengambil data...</span></div>"
            $html += "     <div class='stat-card'><span>👥 Sesi Jaringan Aktif</span><span id='user-stat' class='stat-val'><span class='pulse-dot'></span>Mengambil data...</span></div>"
            $html += "  </div>"
            
            $html += "  <div class='drive-container'>"
            $tbMultiplier = 1GB * 1024
            foreach ($drive in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') }) {
                $dName = $drive.Name; $volLabel = if ($drive.VolumeLabel) { $drive.VolumeLabel } else { "Local Disk" }
                $isActive = if ($currentPath.StartsWith($dName)) { "drive-active" } else { "drive-inactive" }
                $totalSpace = $drive.TotalSize; $freeSpace = $drive.AvailableFreeSpace
                if ($totalSpace -ge $tbMultiplier) { $totFmt = "$([math]::Round($totalSpace / $tbMultiplier, 2)) TB"; $freeFmt = "$([math]::Round($freeSpace / $tbMultiplier, 2)) TB" } 
                else { $totFmt = "$([math]::Round($totalSpace / 1GB, 2)) GB"; $freeFmt = "$([math]::Round($freeSpace / 1GB, 2)) GB" }
                $html += "<a href='/list?dir=$([Uri]::EscapeDataString($dName))' class='drive-btn $isActive'><span>💾 Disk $dName ($volLabel)</span><span style='font-size:12px; font-weight:500; opacity:0.8;'>Tersedia $freeFmt dari $totFmt</span></a>"
            }
            $html += "  </div>"
            
            $html += "  <div class='nav-links'>"
            $html += "     <a href='/list?dir=$([Uri]::EscapeDataString($parentPath))' class='btn-nav'>⬅️ Kembali 1 Folder</a>"
            $html += "     <a href='/list?dir=$([Uri]::EscapeDataString($currentPath))' class='btn-nav btn-nav-primary'>🏠 Muat Ulang Halaman</a>"
            $html += "     <div id='bulk-panel' class='bulk-panel'>"
            $html += "         <span id='bulk-count'>0 item terpilih</span>"
            $html += "         <button onclick='bulkDownload()' class='action-btn' style='background:#10b981;'>📥 Download Massal</button>"
            $html += "         <button onclick='bulkDelete()' class='action-btn' style='background:#ef4444;'>🗑️ Hapus Massal</button>"
            $html += "     </div>"
            $html += "  </div>"
            $html += "</div>"
            
            # [PERBAIKAN] Pastikan value pada search aman (escaped) agar tidak merusak HTML Quotes
            $safeCurrentPath = $currentPath.Replace("'", "&#39;").Replace("`"", "&quot;")
            $safeQ = if ($q) { $q.Replace("'", "&#39;").Replace("`"", "&quot;") } else { "" }

            $html += "<div class='toolbar'>"
            $html += "    <form id='form-search' action='/list' method='GET' onsubmit='validateSearch(event)'>"
            $html += "        <input type='hidden' name='dir' value='$safeCurrentPath'>"
            $html += "        <input type='search' id='searchinput' name='q' placeholder='🔍 Masukan nama file...' value='$safeQ'>"
            $html += "        <button type='submit' class='btn-submit btn-search'>Cari Berkas</button>"
            $html += "    </form><div class='separator'></div>"
            
            $html += "    <form id='form-folder' action='/newfolder?dir=$([Uri]::EscapeDataString($currentPath))' method='POST' onsubmit='validateFolder(event)'>"
            $html += "        <input type='text' id='foldername' name='foldername' placeholder='📁 Masukan nama folder baru...'>"
            $html += "        <button type='submit' class='btn-submit btn-create'>Buat Folder</button>"
            $html += "    </form><div class='separator'></div>"
            
            $html += "    <div id='dropzone' class='dropzone' onclick='document.getElementById(""fileinput"").click()'>"
            $html += "        <span id='drop-text'><b>📥 Klik atau drag n drop file disini</b></span>"
            $html += "        <input type='file' id='fileinput' multiple style='display:none;' onchange='updateFileText()'>"
            $html += "        <button type='button' id='btn-upload-all' onclick='event.stopPropagation(); uploadMultiple()' class='btn-upload' style='display:none;'>Mulai Unggah</button>"
            $html += "    </div>"
            $html += "</div>"
            
            $html += "<div class='table-responsive'>"
            $html += "<table id='fileTable'><tr>"
            $html += "  <th style='width:30px;'><input type='checkbox' onclick='toggleSelectAll(this)'></th>"
            $html += "  <th class='sortable' onclick='sortTable(1, ""str"")'>Nama Berkas <span class='sort-icon'>↕️</span></th>"
            $html += "  <th class='sortable' onclick='sortTable(2, ""date"")'>Tanggal Modifikasi <span class='sort-icon'>↕️</span></th>"
            $html += "  <th class='sortable' onclick='sortTable(3, ""size"")'>Ukuran Berkas <span class='sort-icon'>↕️</span></th>"
            $html += "  <th class='sortable' onclick='sortTable(4, ""str"")'>Tipe <span class='sort-icon'>↕️</span></th>"
            $html += "  <th>Tindakan / Kelola</th>"
            $html += "</tr>"

            if ($items) {
                foreach ($item in $items) {
                    $isDir = $item.PSIsContainer
                    if ($isDir) { $typeBadge = "<span class='type-badge type-folder'>FOLDER</span>"; $icon = "📁" } 
                    else { $typeBadge = "<span class='type-badge type-file'>FILE</span>"; $icon = "📄" }

                    $link = if ($isDir) { "/list?dir=$([Uri]::EscapeDataString($item.FullName))" } else { "#" }
                    $dateMod = $item.LastWriteTime.ToString("dd-MMM-yyyy HH:mm")
                    
                    $sizeStr = "-"
                    $rawSize = 0
                    if (-not $isDir) {
                        $rawSize = $item.Length
                        if ($rawSize -ge 1GB) { $sizeStr = "$([math]::Round($rawSize / 1GB, 2)) GB" }
                        elseif ($rawSize -ge 1MB) { $sizeStr = "$([math]::Round($rawSize / 1MB, 2)) MB" }
                        else { $sizeStr = "$([math]::Round($rawSize / 1KB, 2)) KB" }
                    }

                    $escPath = $([Uri]::EscapeDataString($item.FullName))
                    $escapedName = $item.Name.Replace("\", "\\").Replace("'", "\'")
                    $urlEncodedName = [Uri]::EscapeDataString($item.Name)
                    
                    $isLocked = $global:lockedFiles.ContainsKey($item.FullName)
                    $lockerIP = if ($isLocked) { $global:lockedFiles[$item.FullName] } else { "" }
                    
                    $displayFileName = if ($isLocked) { "🔒 $($item.Name) <span style='font-size:11px;color:#ef4444;font-weight:normal;margin-left:6px;'>(Locked by $lockerIP)</span>" } else { $($item.Name) }
                    
                    $rowAttr = "draggable='true' ondragstart='dragStartRow(event, ""$escPath"")'"
                    if ($isDir) {
                        $rowAttr += " data-foldername='$escapedName' ondragover='dragOverRow(event)' ondragenter='dragEnterRow(event)' ondragleave='dragLeaveRow(event)' ondrop='dropOnRow(event, ""$escPath"", ""$escapedName"")'"
                    }
                    
                    $actions = ""
                    
                    $shareUrl = if ($isDir) { "/list?dir=$escPath" } else { "/download?path=$escPath" }
                    $actions += "<button onclick='copyLink(event, `"$shareUrl`")' class='action-btn' style='background:#0284c7;'>🔗 Share</button>"

                    $actions += "<button onclick='showRenameModal(event, ""$escPath"", ""$escapedName"")' class='action-btn' style='background:#475569;'>✏️ Rename</button>"

                    if ($isDir) {
                        $zipUrl = "/zipfolder?path=$escPath&redir=$([Uri]::EscapeDataString($currentPath))"
                        $actions += "<a href='#' onclick='confirmAction(event, ""$zipUrl"", ""Kompres folder ini menjadi file ZIP?"")' class='action-btn' style='background:#f59e0b;'>🗜️ Zip</a>"
                    } else {
                        $ext = [System.IO.Path]::GetExtension($item.FullName).ToLower()
                        
                        $textExts = @('.txt', '.log', '.ps1', '.ini', '.csv', '.json', '.xml', '.html', '.css', '.js')
                        if ($textExts -contains $ext) {
                            $actions += "<button onclick='editFile(event, ""$escPath"", ""$escapedName"")' class='action-btn' style='background:#f97316;'>📝 Edit</button>"
                        }
                        
                        if ($ext -match "\.(zip|rar)$") {
                            $extUrl = "/extract?path=$escPath&redir=$([Uri]::EscapeDataString($currentPath))"
                            $actions += "<a href='#' onclick='confirmAction(event, ""$extUrl"", ""Yakin ingin mengekstrak file arsip ini?"")' class='action-btn' style='background:#8b5cf6;'>📦 Extract</a>"
                        }
                        $previewUrl = "/preview?path=$escPath"; $printUrl = "/print?path=$escPath"
                        $actions += "<a href='#' onclick='showPreview(event, ""$previewUrl"", ""$printUrl"", ""$escapedName"", ""$ext"")' class='action-btn' style='background:#3b82f6;'>👁️ Prev</a>"
                        $actions += "<a href='/download?path=$escPath' class='action-btn' style='background:#10b981;'>⬇️ DL</a>"
                        
                        if ($isLocked) {
                            $actions += "<a href='#' onclick='confirmAction(event, ""/toggle-lock?path=$escPath&redir=$([Uri]::EscapeDataString($currentPath))"", ""Buka kunci pengaman file ini?"")' class='action-btn' style='background:#ef4444;'>🔓 Unlock</a>"
                        } else {
                            $actions += "<a href='/toggle-lock?path=$escPath&redir=$([Uri]::EscapeDataString($currentPath))' class='action-btn' style='background:#64748b;'>🔒 Lock</a>"
                        }
                    }
                    
                    $delUrl = "/delete?path=$escPath&redir=$([Uri]::EscapeDataString($currentPath))"
                    $actions += "<a href='#' onclick='confirmAction(event, ""$delUrl"", ""Yakin menghapus permanen $escapedName?"")' class='action-btn' style='background:#ef4444;'>🗑️ Del</a>"

                    $html += "<tr $rowAttr>"
                    $html += "  <td><input type='checkbox' class='bulk-checkbox' value='$urlEncodedName' onchange='updateBulkPanelVisibility()'></td>"
                    $html += "  <td>$icon <a href='$link' class='file-link'>$displayFileName</a></td>"
                    $html += "  <td style='font-size:13px;font-weight:600;color:var(--text-muted);'>$dateMod</td>"
                    $html += "  <td data-rawsize='$rawSize' style='font-size:13px;color:var(--text-dark);font-weight:700;'>$sizeStr</td>"
                    $html += "  <td>$typeBadge</td>"
                    $html += "  <td>$actions</td>"
                    $html += "</tr>"
                }
            } else {
                $html += "<tr><td colspan='6' align='center' style='padding:40px; color:var(--text-muted); font-style:italic;'>Tidak ada file atau folder ditemukan di direktori ini.</td></tr>"
            }
            
            $html += "</table></div><footer class='footer'>Powered By Ryuko</footer></div></body></html>"
            
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html); $res.ContentType = "text/html; charset=utf-8"; $res.OutputStream.Write($buffer, 0, $buffer.Length)
            $res.OutputStream.Close()
        }
        
    } catch { 
        $errMsg = $_.Exception.Message
        if ($errMsg -notmatch "network name is no longer available" -and $errMsg -notmatch "nonexistent network connection" -and $errMsg -notmatch "The active connection was aborted") {
            Write-Host "Kesalahan Sistem: $errMsg" -ForegroundColor Red 
        }
    } finally {
        if ($null -ne $res) { try { $res.OutputStream.Close() } catch {} }
    }
}
