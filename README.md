# UTS Pemrograman / Coding Akuntansi (Gasal 2026/2027)
**Departemen Akuntansi, Fakultas Ekonomika dan Bisnis, Universitas Diponegoro**

* **Nama Mahasiswa:** An'nisa Rahmi
* **NIM:** 12030124140304
* **Dosen Pengampu:** Totok Dewayanto
* **Tanggal Ujian:** Selasa, 13 Oktober 2026
* **Demo Web Purwarupa:** [Akses Live Demo GitHub Pages](https://annisarahmi57.github.io/UTS-Pengkodean-dan-Pemograman/voucher_kas_keluar.html) 

---

## 📌 Ringkasan Sistem & Artefak
Repositori ini berisi seluruh artefak kode, skema basis data, trigger, pengujian konkurensi, dan purwarupa antarmuka web untuk Ujian Tengah Semester (UTS) Coding Akuntansi. Seluruh skrip SQL telah diuji langsung pada **PostgreSQL 16** dan divalidasi menggunakan pendekatan keamanan berlapis berbasis database (*database-first enforcement*).

---

## 🏗️ Struktur Repositori

```text
uts-coding-akuntansi/
├── README.md                       <- Dokumentasi & ringkasan repositori
├── sql/
│   ├── 01_schema.sql                 <- Skema relasional, normalisasi, & constraint berpasangan (Soal 1)
│   ├── 02_audit_immutability_rpc.sql <- Audit trail, hash chain SHA-256, storno, & RPC (Soal 3.2)
│   ├── 03_inventory.sql              <- Sistem persediaan perpetual & trigger otomatis (Soal 2.1)
│   ├── 04_supabase_privileges.sql    <- Hak akses RLS & keamanan Supabase
│   ├── 90_test_soal1.sql             <- Skrip uji integritas Soal 1
│   ├── 91_test_soal2.sql             <- Skrip uji persediaan & race condition Soal 2
│   ├── 92_test_soal3.sql             <- Skrip uji immutability & audit trail Soal 3
│   ├── 93_test_privileges.sql        <- Skrip uji hak akses role
│   ├── 94_serializable_retry.js      <- Pola retry transaksi SERIALIZABLE (Node.js)
│   └── run_all.sh                    <- Skrip otomatisasi pengujian total
├── web/
│   └── voucher_kas_keluar.html       <- Purwarupa UI interaktif (Tailwind CSS + Supabase RPC)
└── docs/
    └── erd.png                       <- Diagram ERD General Ledger
