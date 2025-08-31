# 🔄 KanaCloud Auto Backup v2.5

**KanaAutoBackup** adalah script **bash** untuk melakukan **backup otomatis** data Pterodactyl VPS ke beberapa destinasi penyimpanan:

* ✅ **VPS Host** (server backup utama)
* ✅ **Google Drive** (via Rclone)
* ✅ **iCloud+** (opsional)
* ✅ **Live Sync antar VPS**

Mendukung **kompresi multi-threaded (pigz)**, **upload paralel**, dan **monitoring real-time**.

---

## 📂 Fitur Utama

* 🔹 Backup penuh `/var/lib/pterodactyl/volumes`
* 🔹 Upload ke **Google Drive** dan **iCloud+** via `rclone`
* 🔹 Upload ke **VPS Host** via `rsync` & `sshpass`
* 🔹 **Live Sync** antar VPS
* 🔹 **Kompresi cepat** dengan pigz
* 🔹 **Monitoring** penggunaan disk & proses aktif
* 🔹 **Parallel backup** (max 3 VPS sekaligus)
* 🔹 **Auto-verify upload** menggunakan `rclone check`

---

## 🛠️ Persyaratan

Dependensi yang dibutuhkan:

```
sshpass
rclone
pv
pigz
rsync
coreutils (numfmt)
```

### Instalasi Otomatis

Gunakan menu **Install Dependencies** atau jalankan:

```bash
apt update && apt install -y sshpass rclone pv pigz rsync coreutils
```

---

## ⚙️ Konfigurasi

Script menggunakan variabel di bagian atas:

* **RCLONE\_REMOTE** → Nama remote Google Drive di rclone
* **ICLOUD\_REMOTE** → Nama remote iCloud+
* **BACKUP\_HOST** → IP VPS backup utama
* **VPS\_IPS** & **VPS\_PASSWORDS** → Daftar VPS dan password

Contoh:

```bash
declare -A VPS_IPS=(
    ["SGP1"]="178.128.16.199"
    ["PVN_Premi1"]="167.172.77.159"
)

declare -A VPS_PASSWORDS=(
    ["SGP1"]="Admin123AS"
    ["PVN_Premi1"]="Admin123AS"
)
```

---

## ▶️ Cara Menjalankan

1. Jadikan file executable:

```bash
chmod +x "KANAAUTOBACKUP 2.5 FINAL.sh"
```

2. Jalankan:

```bash
./KANAAUTOBACKUP\ 2.5\ FINAL.sh
```

---

## 📜 Menu Utama

```
1) Backup to VPS Host only
2) Backup to Google Drive only
3) Backup to iCloud+ only
4) Backup to both VPS Host and Google Drive
5) Backup to all destinations (VPS, Drive, iCloud+)
6) Monitor running backups
7) View configuration
8) Install Dependencies
9) Clean Remote Path
10) Select Specific VPS
11) Exit
```

---

## 📌 Mode Backup

* `vps-only` → Hanya VPS Host
* `drive-only` → Hanya Google Drive
* `icloud-only` → Hanya iCloud+
* `both` → VPS Host + Google Drive
* `all` → Semua destinasi

---

## 🔍 Monitoring

Opsi **6) Monitor running backups** akan menampilkan:

* Proses aktif (`rsync`, `rclone`, `tar`, dll)
* Disk usage

---

## ⚠️ Keamanan

* Jangan commit script ini dengan password ke repo publik
* Simpan `rclone.conf` di lokasi aman
* Gunakan **cron job** hanya di server yang aman

---

## ✅ Fitur Tambahan

* Auto-verify upload dengan `rclone check`
* Clean remote path jika file lama ada
* Live sync otomatis setelah backup

---

### 🧩 To-Do:

* [ ] Notifikasi Telegram setelah backup selesai
* [ ] Incremental backup support
* [ ] Log upload ke JSON untuk analitik

---

📌 **Lisensi:** MIT
📌 **Dikembangkan oleh:** Cahya

---

Sekarang kamu punya dua README terpisah.
Apakah kamu mau saya **buatkan struktur folder GitHub beserta kedua README ini** (contohnya `discord-bot/README.md` dan `autobackup/README.md`)? Atau **satu repo dengan dua folder**?
