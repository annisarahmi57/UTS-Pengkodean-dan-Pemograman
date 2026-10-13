\set VERBOSITY terse
\echo '--- T1.1 CHECK: debit negatif'
INSERT INTO journal_headers(trx_date,reference_no,description) VALUES ('2026-10-01','T-001','uji');
INSERT INTO journal_lines(header_id,account_id,debit,credit) VALUES (1,1,-5,0);
\echo '--- T1.2 CHECK: debit=0 dan credit=0'
INSERT INTO journal_lines(header_id,account_id,debit,credit) VALUES (1,1,0,0);
\echo '--- T1.3 CHECK: debit dan credit sekaligus > 0'
INSERT INTO journal_lines(header_id,account_id,debit,credit) VALUES (1,1,10,10);
\echo '--- T1.4 FK RESTRICT: hapus akun yang dipakai'
INSERT INTO journal_lines(header_id,account_id,debit,credit) VALUES (1,1,100,0);
DELETE FROM chart_of_accounts WHERE account_id=1;
\echo '--- T1.5 Bypass frontend: POSTED tak seimbang lewat SQL/API langsung'
UPDATE journal_headers SET posting_status='POSTED' WHERE header_id=1;
\echo '--- T1.6 Jurnal seimbang -> sukses'
INSERT INTO journal_lines(header_id,account_id,debit,credit) VALUES (1,2,0,100);
UPDATE journal_headers SET posting_status='POSTED' WHERE header_id=1;
SELECT header_id,posting_status,posting_seq,left(hash_checksum,16) hash16 FROM journal_headers;
\echo '--- T1.7 Deferred constraint: INSERT header langsung POSTED dalam satu transaksi (lines menyusul)'
BEGIN;
INSERT INTO journal_headers(trx_date,reference_no,description,posting_status,posted_by,posted_at,posting_seq,hash_checksum)
 VALUES ('2026-10-01','T-002','langsung posted','POSTED','x',now(),999,repeat('a',64));
COMMIT;
