\set VERBOSITY terse
INSERT INTO inventory_items VALUES ('BRG001','Kertas A4 (rim)',0,10000.00);
\echo '--- T2.1 PURCHASE 10 -> stok 10'
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','PURCHASE',10);
SELECT item_id, stock_qty FROM inventory_items;
\echo '--- T2.2 SALE 3 -> stok 7'
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','SALE',3);
SELECT item_id, stock_qty FROM inventory_items;
\echo '--- T2.3 SALE 8 (> stok 7) -> ditolak, stok tetap, tidak ada baris transaksi/jurnal'
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','SALE',8);
SELECT stock_qty FROM inventory_items;
SELECT count(*) AS trx_rows FROM inventory_transactions;
\echo '--- T2.4 ADJUSTMENT -2 (susut/retur pembelian) dan +1 (retur penjualan/selisih lebih)'
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','ADJUSTMENT',-2);
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','ADJUSTMENT',1);
\echo '--- T2.5 qty tidak valid & item tidak ada'
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('BRG001','SALE',0);
INSERT INTO inventory_transactions(item_id,trx_type,qty) VALUES ('XXX','SALE',1);
\echo '--- T2.6 Jurnal otomatis'
SELECT h.reference_no, c.account_code, l.debit, l.credit
  FROM journal_headers h JOIN journal_lines l USING(header_id) JOIN chart_of_accounts c USING(account_id)
 WHERE h.reference_no LIKE 'INVTRX-%' ORDER BY h.header_id, l.line_id;
\echo '--- T2.7 Rekonsiliasi GL vs sub-ledger'
SELECT * FROM v_inventory_reconciliation;
SELECT item_id, stock_qty, stock_qty*unit_cost AS nilai FROM inventory_items;
\echo '--- T2.8 Riwayat mutasi tak boleh diubah'
UPDATE inventory_transactions SET qty=999 WHERE trx_id=1;
DELETE FROM inventory_transactions WHERE trx_id=1;
