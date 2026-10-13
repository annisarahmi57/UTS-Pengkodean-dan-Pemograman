-- =====================================================================
-- UTS Coding Akuntansi - SOAL 2: Persediaan perpetual, trigger, concurrency
-- Prasyarat: 01_schema.sql, 02_audit_immutability_rpc.sql
-- =====================================================================

-- Struktur tabel PERSIS seperti yang diberikan di soal ---------------
CREATE TABLE inventory_items (
    item_id    VARCHAR(10) PRIMARY KEY,
    item_name  VARCHAR(100),
    stock_qty  INT NOT NULL DEFAULT 0,
    unit_cost  NUMERIC(15, 2) NOT NULL
);

CREATE TABLE inventory_transactions (
    trx_id    SERIAL PRIMARY KEY,
    item_id   VARCHAR(10) REFERENCES inventory_items(item_id),
    trx_type  VARCHAR(10) CHECK (trx_type IN ('PURCHASE', 'SALE', 'ADJUSTMENT')),
    qty       INT NOT NULL,
    trx_date  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Pertahanan lapis terakhir (di luar permintaan soal, sangat disarankan):
ALTER TABLE inventory_items
    ADD CONSTRAINT ck_stock_nonneg CHECK (stock_qty >= 0);

-- Akun yang dipakai trigger (kode akun contoh) ------------------------
INSERT INTO chart_of_accounts(account_code, account_name, normal_balance, report_class, is_cash) VALUES
 ('1-1100','Kas dan Setara Kas',            'DEBIT', 'NERACA',    TRUE),
 ('1-1300','Persediaan Barang Dagang',      'DEBIT', 'NERACA',    FALSE),
 ('2-1100','Utang Usaha',                   'CREDIT','NERACA',    FALSE),
 ('5-1100','Beban Pokok Pendapatan (HPP)',  'DEBIT', 'LABA_RUGI', FALSE),
 ('5-9000','Selisih Persediaan',            'DEBIT', 'LABA_RUGI', FALSE);

-- =====================================================================
-- 2.1  TRIGGER FUNCTION
-- =====================================================================
CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_stock   INT;
    v_cost    NUMERIC(15,2);
    v_delta   INT;
    v_amount  NUMERIC(18,2);
    v_dr      TEXT;
    v_cr      TEXT;
    v_desc    TEXT;
BEGIN
    -- Validasi tanda qty -------------------------------------------------
    IF NEW.trx_type IN ('PURCHASE','SALE') AND NEW.qty <= 0 THEN
        RAISE EXCEPTION 'Qty % harus > 0 untuk transaksi %', NEW.qty, NEW.trx_type;
    ELSIF NEW.trx_type = 'ADJUSTMENT' AND NEW.qty = 0 THEN
        RAISE EXCEPTION 'Qty ADJUSTMENT tidak boleh 0 (positif = menambah, negatif = mengurangi)';
    END IF;

    -- (a) KUNCI baris item, lalu baca saldo TERBARU ----------------------
    SELECT stock_qty, unit_cost INTO v_stock, v_cost
      FROM inventory_items WHERE item_id = NEW.item_id
       FOR UPDATE;                                   -- <- kunci anti race-condition
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % tidak ditemukan', NEW.item_id;
    END IF;

    v_delta := CASE NEW.trx_type WHEN 'SALE' THEN -NEW.qty ELSE NEW.qty END;

    -- (b) Anti-negative inventory ---------------------------------------
    IF v_stock + v_delta < 0 THEN
        RAISE EXCEPTION 'Stok % tidak cukup: tersedia %, diminta % (transaksi dibatalkan)',
                        NEW.item_id, v_stock, ABS(v_delta)
              USING ERRCODE = 'check_violation',
                    HINT = 'Periksa stok aktual atau lakukan pembelian/penyesuaian terlebih dahulu';
    END IF;

    UPDATE inventory_items SET stock_qty = v_stock + v_delta WHERE item_id = NEW.item_id;

    -- (c) Jurnal otomatis ke buku besar (sistem perpetual) --------------
    v_amount := round(ABS(v_delta) * v_cost, 2);
    IF v_amount = 0 THEN RETURN NULL; END IF;        -- barang bernilai nol: tidak ada jurnal

    IF NEW.trx_type = 'PURCHASE' THEN
        v_dr := '1-1300'; v_cr := '2-1100'; v_desc := 'Pembelian persediaan ';
    ELSIF NEW.trx_type = 'SALE' THEN
        v_dr := '5-1100'; v_cr := '1-1300'; v_desc := 'HPP penjualan ';
    ELSIF v_delta > 0 THEN
        v_dr := '1-1300'; v_cr := '5-9000'; v_desc := 'Penyesuaian persediaan (+) ';
    ELSE
        v_dr := '5-9000'; v_cr := '1-1300'; v_desc := 'Penyesuaian persediaan (-) ';
    END IF;

    PERFORM fn_create_and_post_journal(
        NEW.trx_date::date,
        'INVTRX-' || NEW.trx_id,
        v_desc || NEW.item_id || ' x ' || ABS(v_delta),
        jsonb_build_array(
            jsonb_build_object('account_code', v_dr, 'debit',  v_amount, 'credit', 0),
            jsonb_build_object('account_code', v_cr, 'debit',  0,        'credit', v_amount)));
    RETURN NULL;
END $$;

CREATE TRIGGER trg_inventory_after_insert
    AFTER INSERT ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_update_stock_and_journal();

-- Riwayat mutasi tidak boleh diubah/dihapus (koreksi = transaksi ADJUSTMENT)
CREATE TRIGGER trg_inventory_trx_immutable
    BEFORE UPDATE OR DELETE ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_deny_change();

CREATE TRIGGER trg_audit_inv_items AFTER INSERT OR UPDATE OR DELETE ON inventory_items
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('item_id');
CREATE TRIGGER trg_audit_inv_trx   AFTER INSERT OR UPDATE OR DELETE ON inventory_transactions
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('trx_id');

-- Query rekonsiliasi (stock opname): nilai buku besar vs nilai fisik -----
CREATE OR REPLACE VIEW v_inventory_reconciliation AS
SELECT (SELECT COALESCE(SUM(l.debit - l.credit),0)
          FROM journal_lines l JOIN chart_of_accounts c USING (account_id)
          JOIN journal_headers h USING (header_id)
         WHERE c.account_code = '1-1300' AND h.posting_status = 'POSTED')   AS saldo_gl_persediaan,
       (SELECT COALESCE(SUM(stock_qty * unit_cost),0) FROM inventory_items) AS nilai_subledger,
       (SELECT COALESCE(SUM(l.debit - l.credit),0)
          FROM journal_lines l JOIN chart_of_accounts c USING (account_id)
          JOIN journal_headers h USING (header_id)
         WHERE c.account_code = '1-1300' AND h.posting_status = 'POSTED')
       - (SELECT COALESCE(SUM(stock_qty * unit_cost),0) FROM inventory_items) AS selisih;
