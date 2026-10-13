-- =====================================================================
-- UTS Coding Akuntansi - SOAL 3.2: Audit trail, immutability, storno, hash
-- Prasyarat: 01_schema.sql
-- =====================================================================

-- ---------------------------------------------------------------
-- 1. Audit log append-only
-- ---------------------------------------------------------------
CREATE TABLE audit_log (
    log_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name  TEXT        NOT NULL,
    record_id   TEXT        NOT NULL,
    action      TEXT        NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT        NOT NULL DEFAULT fn_current_actor(),
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    txid        BIGINT      NOT NULL DEFAULT txid_current()
);

CREATE OR REPLACE FUNCTION trg_audit_row() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_old JSONB := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
        v_new JSONB := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
BEGIN
    INSERT INTO audit_log(table_name, record_id, action, old_data, new_data)
    VALUES (TG_TABLE_NAME, COALESCE(v_new, v_old) ->> TG_ARGV[0], TG_OP, v_old, v_new);
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION trg_deny_change() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% pada % ditolak: tabel ini append-only', TG_OP, TG_TABLE_NAME
          USING ERRCODE = 'restrict_violation';
END $$;

CREATE TRIGGER trg_audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION trg_deny_change();
CREATE TRIGGER trg_audit_log_no_truncate BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION trg_deny_change();

CREATE TRIGGER trg_audit_headers AFTER INSERT OR UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('header_id');
CREATE TRIGGER trg_audit_lines   AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('line_id');
CREATE TRIGGER trg_audit_coa     AFTER INSERT OR UPDATE OR DELETE ON chart_of_accounts
    FOR EACH ROW EXECUTE FUNCTION trg_audit_row('account_id');

-- ---------------------------------------------------------------
-- 2. hash_checksum: SHA-256 berantai (hash chain)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_compute_journal_hash(h journal_headers, p_prev TEXT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
  SELECT encode(sha256(convert_to(
           COALESCE(p_prev, 'GENESIS')                                   || '|' ||
           h.header_id::text                                              || '|' ||
           h.reference_no                                                 || '|' ||
           h.trx_date::text                                               || '|' ||
           h.description                                                  || '|' ||
           COALESCE(h.reversal_of::text, '-')                             || '|' ||
           h.created_by                                                   || '|' ||
           to_char(h.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
           COALESCE((SELECT string_agg(l.account_id || ':' || l.debit || ':' || l.credit,
                                       ',' ORDER BY l.line_id)
                       FROM journal_lines l WHERE l.header_id = h.header_id), ''),
         'UTF8')), 'hex');
$$;

-- ---------------------------------------------------------------
-- 3. Gerbang status POSTED (header)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_guard_journal_header() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Jurnal % berstatus POSTED tidak boleh dihapus. Gunakan jurnal pembalik (rpc_reverse_journal).', OLD.reference_no
                  USING ERRCODE = 'restrict_violation';
        END IF;
        RETURN OLD;
    END IF;

    -- UPDATE
    IF OLD.posting_status = 'POSTED' THEN
        RAISE EXCEPTION 'Jurnal % berstatus POSTED tidak boleh diubah. Gunakan jurnal pembalik (rpc_reverse_journal).', OLD.reference_no
              USING ERRCODE = 'restrict_violation';
    END IF;

    NEW.created_by := OLD.created_by;           -- identitas pembuat tidak dapat dipalsukan
    NEW.created_at := OLD.created_at;

    IF NEW.posting_status = 'POSTED' THEN       -- satu-satunya transisi sah: DRAFT -> POSTED
        PERFORM pg_advisory_xact_lock(hashtext('journal_hash_chain'));   -- serialisasi rantai hash
        PERFORM fn_assert_balanced(NEW.header_id, TRUE);                  -- cek segera, bukan hanya saat COMMIT
        NEW.posted_by   := fn_current_actor();
        NEW.posted_at   := now();
        NEW.posting_seq := nextval('seq_posting_no');
        SELECT hash_checksum INTO NEW.prev_hash
          FROM journal_headers WHERE posting_seq IS NOT NULL
         ORDER BY posting_seq DESC LIMIT 1;
        NEW.hash_checksum := fn_compute_journal_hash(NEW, NEW.prev_hash);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_guard_header BEFORE UPDATE OR DELETE ON journal_headers
    FOR EACH ROW EXECUTE FUNCTION trg_guard_journal_header();

-- ---------------------------------------------------------------
-- 4. Gerbang baris jurnal: tidak ada INSERT/UPDATE/DELETE pada header POSTED
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_guard_journal_line() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_ref TEXT;
BEGIN
    SELECT reference_no INTO v_ref FROM journal_headers
     WHERE posting_status = 'POSTED'
       AND header_id IN (CASE WHEN TG_OP <> 'INSERT' THEN OLD.header_id END,
                         CASE WHEN TG_OP <> 'DELETE' THEN NEW.header_id END);
    IF FOUND THEN
        RAISE EXCEPTION 'Baris jurnal % tidak boleh % karena jurnal berstatus POSTED. Gunakan jurnal pembalik.', v_ref, TG_OP
              USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER trg_guard_line BEFORE INSERT OR UPDATE OR DELETE ON journal_lines
    FOR EACH ROW EXECUTE FUNCTION trg_guard_journal_line();

CREATE TRIGGER trg_no_truncate_headers BEFORE TRUNCATE ON journal_headers
    FOR EACH STATEMENT EXECUTE FUNCTION trg_deny_change();
CREATE TRIGGER trg_no_truncate_lines   BEFORE TRUNCATE ON journal_lines
    FOR EACH STATEMENT EXECUTE FUNCTION trg_deny_change();

-- ---------------------------------------------------------------
-- 5. Fungsi inti: buat + posting jurnal secara atomik
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_create_and_post_journal(
    p_trx_date DATE, p_reference_no TEXT, p_description TEXT,
    p_lines JSONB, p_reversal_of BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_line JSONB; v_acc INT; v_dr NUMERIC; v_cr NUMERIC;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'Jurnal harus berisi minimal 2 baris' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO journal_headers(trx_date, reference_no, description, reversal_of)
    VALUES (p_trx_date, p_reference_no, p_description, p_reversal_of)
    RETURNING header_id INTO v_id;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        SELECT account_id INTO v_acc FROM chart_of_accounts
         WHERE account_code = v_line ->> 'account_code' AND is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Akun % tidak ditemukan atau nonaktif', v_line ->> 'account_code'
                  USING ERRCODE = 'foreign_key_violation';
        END IF;
        v_dr := COALESCE((v_line ->> 'debit')::numeric, 0);
        v_cr := COALESCE((v_line ->> 'credit')::numeric, 0);
        IF v_dr <> round(v_dr, 2) OR v_cr <> round(v_cr, 2) THEN
            RAISE EXCEPTION 'Nominal maksimal 2 desimal (akun %)', v_line ->> 'account_code'
                  USING ERRCODE = 'check_violation';
        END IF;
        INSERT INTO journal_lines(header_id, account_id, debit, credit)
        VALUES (v_id, v_acc, v_dr, v_cr);
    END LOOP;

    UPDATE journal_headers SET posting_status = 'POSTED' WHERE header_id = v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------
-- 6. RPC voucher kas keluar (dipanggil frontend: supabase.rpc(...))
--    Aturan bisnis: kas keluar harus mengurangi kas & setara kas (net > 0)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_post_cash_disbursement(
    p_trx_date DATE, p_reference_no TEXT, p_description TEXT, p_lines JSONB)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_net NUMERIC;
BEGIN
    IF p_trx_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'Tanggal voucher tidak boleh di masa depan' USING ERRCODE = 'check_violation';
    END IF;

    -- COALESCE per baris: kunci debit/credit yang tidak dikirim dianggap 0
    SELECT COALESCE(SUM(COALESCE((e ->> 'credit')::numeric, 0) - COALESCE((e ->> 'debit')::numeric, 0)), 0)
      INTO v_net
      FROM jsonb_array_elements(p_lines) e
      JOIN chart_of_accounts c ON c.account_code = e ->> 'account_code' AND c.is_cash;
    IF v_net <= 0 THEN
        RAISE EXCEPTION 'Voucher kas keluar harus mengkredit akun kas/bank (net kas keluar > 0)'
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN fn_create_and_post_journal(p_trx_date, p_reference_no, p_description, p_lines);
END $$;

-- ---------------------------------------------------------------
-- 7. RPC jurnal pembalik (storno)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_reverse_journal(
    p_header_id BIGINT, p_reason TEXT, p_trx_date DATE DEFAULT CURRENT_DATE)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_orig journal_headers; v_lines JSONB;
BEGIN
    IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
        RAISE EXCEPTION 'Alasan pembalikan wajib diisi (minimal 5 karakter)' USING ERRCODE = 'check_violation';
    END IF;

    SELECT * INTO v_orig FROM journal_headers WHERE header_id = p_header_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Jurnal % tidak ditemukan', p_header_id; END IF;
    IF v_orig.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya jurnal POSTED yang dapat dibalik (jurnal DRAFT cukup dihapus)';
    END IF;
    IF v_orig.reversal_of IS NOT NULL THEN
        RAISE EXCEPTION 'Jurnal % adalah jurnal pembalik dan tidak dapat dibalik lagi', v_orig.reference_no;
    END IF;
    IF EXISTS (SELECT 1 FROM journal_headers WHERE reversal_of = p_header_id) THEN
        RAISE EXCEPTION 'Jurnal % sudah pernah dibalik', v_orig.reference_no;
    END IF;

    SELECT jsonb_agg(jsonb_build_object('account_code', c.account_code,
                                        'debit',  l.credit,          -- sisi ditukar
                                        'credit', l.debit) ORDER BY l.line_id)
      INTO v_lines
      FROM journal_lines l JOIN chart_of_accounts c USING (account_id)
     WHERE l.header_id = p_header_id;

    RETURN fn_create_and_post_journal(
        p_trx_date, 'REV-' || v_orig.reference_no,
        'Pembalik ' || v_orig.reference_no || ': ' || btrim(p_reason),
        v_lines, p_header_id);
END $$;

-- ---------------------------------------------------------------
-- 8. Verifikasi integritas rantai hash
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verify_ledger()
RETURNS TABLE(header_id BIGINT, reference_no TEXT, posting_seq BIGINT, is_valid BOOLEAN, reason TEXT)
LANGUAGE plpgsql STABLE AS $$
DECLARE r journal_headers; v_prev TEXT := NULL; v_calc TEXT; v_dr NUMERIC; v_cr NUMERIC;
BEGIN
    FOR r IN SELECT * FROM journal_headers h WHERE h.posting_status = 'POSTED' ORDER BY h.posting_seq LOOP
        header_id := r.header_id; reference_no := r.reference_no; posting_seq := r.posting_seq;
        is_valid := TRUE; reason := 'OK';
        SELECT COALESCE(SUM(l.debit),0), COALESCE(SUM(l.credit),0) INTO v_dr, v_cr
          FROM journal_lines l WHERE l.header_id = r.header_id;
        v_calc := fn_compute_journal_hash(r, r.prev_hash);
        IF r.prev_hash IS DISTINCT FROM v_prev THEN
            is_valid := FALSE; reason := 'Rantai putus: prev_hash tidak cocok (ada jurnal dihapus/disisipkan)';
        ELSIF v_calc <> r.hash_checksum THEN
            is_valid := FALSE; reason := 'hash_checksum tidak cocok: isi jurnal berubah setelah posting';
        ELSIF v_dr <> v_cr THEN
            is_valid := FALSE; reason := 'Debit <> Kredit';
        END IF;
        v_prev := r.hash_checksum;
        RETURN NEXT;
    END LOOP;
END $$;

CREATE OR REPLACE VIEW v_journal_status AS
SELECT h.header_id, h.reference_no, h.trx_date, h.posting_status,
       h.reversal_of, rv.header_id AS reversed_by_id,
       (rv.header_id IS NOT NULL) AS is_reversed
  FROM journal_headers h
  LEFT JOIN journal_headers rv ON rv.reversal_of = h.header_id;
