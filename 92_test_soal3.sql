\set VERBOSITY terse
INSERT INTO chart_of_accounts(account_code,account_name,normal_balance,report_class,is_cash) VALUES
 ('1-1200','Bank BCA','DEBIT','NERACA',TRUE),
 ('6-1100','Beban Listrik','DEBIT','LABA_RUGI',FALSE);
SET app.user_id = 'kasir-01';
\echo '--- T3.1 voucher kas keluar seimbang'
SELECT rpc_post_cash_disbursement('2026-10-10','KK-001','Bayar listrik Oktober',
 '[{"account_code":"6-1100","debit":1500000},{"account_code":"1-1200","credit":1500000}]'::jsonb) AS header_id;
\echo '--- T3.2 voucher tidak seimbang (2 baris tapi nominal beda) via RPC'
SELECT rpc_post_cash_disbursement('2026-10-10','KK-002','salah',
 '[{"account_code":"6-1100","debit":1500000},{"account_code":"1-1200","credit":1400000}]'::jsonb);
\echo '--- T3.3 voucher tanpa akun kas'
SELECT rpc_post_cash_disbursement('2026-10-10','KK-003','tanpa kas',
 '[{"account_code":"6-1100","debit":100},{"account_code":"2-1100","credit":100}]'::jsonb);
\echo '--- T3.4 nominal 3 desimal / akun tak dikenal / tanggal masa depan'
SELECT rpc_post_cash_disbursement('2026-10-10','KK-004','x','[{"account_code":"6-1100","debit":10.005},{"account_code":"1-1200","credit":10.005}]'::jsonb);
SELECT rpc_post_cash_disbursement('2026-10-10','KK-005','x','[{"account_code":"9-9999","debit":10},{"account_code":"1-1200","credit":10}]'::jsonb);
SELECT rpc_post_cash_disbursement('2099-01-01','KK-006','x','[{"account_code":"6-1100","debit":10},{"account_code":"1-1200","credit":10}]'::jsonb);
\echo '--- T3.5 UPDATE / DELETE jurnal POSTED, UPDATE / DELETE baris, TRUNCATE'
UPDATE journal_headers SET description='diubah' WHERE reference_no='KK-001';
UPDATE journal_headers SET posting_status='DRAFT' WHERE reference_no='KK-001';
DELETE FROM journal_headers WHERE reference_no='KK-001';
UPDATE journal_lines SET debit=1 WHERE header_id=(SELECT header_id FROM journal_headers WHERE reference_no='KK-001') AND debit>0;
DELETE FROM journal_lines WHERE header_id=(SELECT header_id FROM journal_headers WHERE reference_no='KK-001');
INSERT INTO journal_lines(header_id,account_id,debit,credit) SELECT header_id,1,5,0 FROM journal_headers WHERE reference_no='KK-001';
TRUNCATE journal_lines;
TRUNCATE journal_headers CASCADE;
\echo '--- T3.6 storno'
SELECT rpc_reverse_journal((SELECT header_id FROM journal_headers WHERE reference_no='KK-001'),'Salah akun, seharusnya beban air') AS rev_id;
SELECT rpc_reverse_journal((SELECT header_id FROM journal_headers WHERE reference_no='KK-001'),'dibalik dua kali');
SELECT rpc_reverse_journal((SELECT header_id FROM journal_headers WHERE reference_no='REV-KK-001'),'balik pembalik');
SELECT rpc_reverse_journal((SELECT header_id FROM journal_headers WHERE reference_no='KK-001'),'x');
SELECT h.reference_no, c.account_code, l.debit, l.credit
  FROM journal_headers h JOIN journal_lines l USING(header_id) JOIN chart_of_accounts c USING(account_id)
 WHERE h.reference_no IN ('KK-001','REV-KK-001') ORDER BY h.header_id, l.line_id;
SELECT reference_no, posting_status, is_reversed, reversed_by_id FROM v_journal_status ORDER BY header_id;
\echo '--- T3.7 hash chain valid'
SELECT * FROM fn_verify_ledger();
SELECT header_id, created_by, posted_by, posting_seq, left(prev_hash,12) prev, left(hash_checksum,12) hash FROM journal_headers ORDER BY posting_seq;
\echo '--- T3.8 audit_log tak bisa diubah'
UPDATE audit_log SET changed_by='hacker';
DELETE FROM audit_log;
TRUNCATE audit_log;
SELECT table_name, action, count(*) FROM audit_log GROUP BY 1,2 ORDER BY 1,2;
\echo '--- T3.9 Simulasi tamper oleh superuser (trigger dimatikan) -> terdeteksi hash'
ALTER TABLE journal_lines DISABLE TRIGGER trg_guard_line;
ALTER TABLE journal_lines DISABLE TRIGGER ctrg_balance_lines;
UPDATE journal_lines SET debit=1400000 WHERE debit=1500000;
UPDATE journal_lines SET credit=1400000 WHERE credit=1500000 AND header_id=(SELECT header_id FROM journal_headers WHERE reference_no='KK-001');
SELECT header_id, reference_no, is_valid, reason FROM fn_verify_ledger();
ALTER TABLE journal_lines ENABLE TRIGGER trg_guard_line;
ALTER TABLE journal_lines ENABLE TRIGGER ctrg_balance_lines;
