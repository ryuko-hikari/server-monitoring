# Windows Server & Network Monitoring to Discord

Untuk memantau kesehatan Windows Server secara real-time dan mengirimkan laporannya langsung ke channel Discord melalui Webhook. Cocok digunakan untuk admin IT yang mengelola server tunggal tanpa perlu menginstal software monitoring yang berat.

## 📊 Fitur Utama
* **Status Jaringan** : Mengecek konektivitas internet secara otomatis.
* **Sesi Akses User** : Memantau jumlah perangkat yang sedang mengakses folder sharing (SMB) di server.
* **Monitoring RAM** : Menampilkan sisa RAM yang tersedia.
* **Monitoring Disk (Warna Indikator)** :
    * `+ [SAFE]` (Hijau): Sisa kapasitas > 50%.
    * `[WARNING]` (Kuning): Sisa kapasitas < 50%.
    * `- [CRITICAL]` (Merah): Sisa kapasitas < 20%.
* **Timestamp Otomatis**: Laporan dilengkapi dengan hari, tanggal, dan jam pengiriman.

## 🚀 Persiapan
1. **Discord Webhook**:
    * Buka channel Discord Anda.
    * Pergi ke `Integrations` > `Webhooks` > `New Webhook`.
    * Salin **Webhook URL** Anda.
2. **Konfigurasi Skrip**:
    * Buka file `monitor_server.ps1`.
    * Tempel URL Webhook Anda pada variabel `$webhookURL`.

## 🛠️ Cara Penggunaan
1. Jalankan PowerShell sebagai Administrator.
2. Atur izin eksekusi jika belum aktif:
   ```powershell
   Set-ExecutionPolicy RemoteSigned -Force

3.Jalankan skrip secara manual untuk pengetesan : 
.\monitor_server.ps1

📅 Otomatisasi (Task Scheduler)
Untuk mengirim laporan otomatis (misal: setiap jam 08:00 dan 17:00), gunakan Windows Task Scheduler :
1. Buat tugas baru (Create Basic Task).
2. Pilih Trigger Daily dan atur waktunya.
3. Pada Action, pilih Start a Program.
   * Program/script : powershell.exe
   * Arguments: -ExecutionPolicy Bypass -File "C:\path\ke\skrip\anda\monitor_server.ps1"
4. Centang Run with highest privileges agar fitur monitoring sesi user aktif.

📝 Catatan
Pastikan file disimpan dengan encoding UTF-8 atau ANSI untuk menghindari error pembacaan karakter pada PowerShell.
