-- =====================================================================
-- UTS Coding Akuntansi - SOAL 1: Skema General Ledger + integritas
-- PostgreSQL 14+ (diuji pada PostgreSQL 16)
-- =====================================================================

-- ---------------------------------------------------------------
-- 0. Helper: identitas pelaku (Supabase JWT -> app.user_id -> role DB)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_current_actor() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
           NULLIF(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', ''),
           NULLIF(current_setting('app.user_id', true), ''),
           session_user::text);
$$;

-- ---------------------------------------------------------------
-- 1. chart_of_accounts
-- ---------------------------------------------------------------
CREATE TABLE chart_of_accounts (
    account_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_code    VARCHAR(20)  NOT NULL UNIQUE,
    account_name    VARCHAR(100) NOT NULL,
    normal_balance  VARCHAR(6)   NOT NULL
        CONSTRAINT ck_coa_normal_balance CHECK (normal_balance IN ('DEBIT','CREDIT')),
    report_class    VARCHAR(12)  NOT NULL
        CONSTRAINT ck_coa_report_class CHECK (report_class IN ('NERACA','LABA_RUGI')),
    is_cash         BOOLEAN      NOT NULL DEFAULT FALSE,   -- kas & setara kas
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------
-- 2. journal_headers
-- ---------------------------------------------------------------
CREATE SEQUENCE seq_posting_no;

CREATE TABLE journal_headers (
    header_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trx_date        DATE         NOT NULL,
    reference_no    VARCHAR(50)  NOT NULL UNIQUE,           -- nomor bukti
    description     TEXT         NOT NULL,
    posting_status  VARCHAR(10)  NOT NULL DEFAULT 'DRAFT'
        CONSTRAINT ck_jh_status CHECK (posting_status IN ('DRAFT','POSTED')),
    -- jurnal pembalik: menunjuk jurnal asal; UNIQUE => satu jurnal hanya bisa dibalik sekali
    reversal_of     BIGINT UNIQUE REFERENCES journal_headers(header_id) ON DELETE RESTRICT,
    -- kolom jejak audit (dipakai Soal 3)
    created_by      TEXT         NOT NULL DEFAULT fn_current_actor(),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    posted_by       TEXT,
    posted_at       TIMESTAMPTZ,
    posting_seq     BIGINT UNIQUE,                          -- urutan rantai hash
    prev_hash       CHAR(64),
    hash_checksum   CHAR(64),
    CONSTRAINT ck_jh_posted_complete CHECK (
        (posting_status = 'POSTED'
            AND hash_checksum IS NOT NULL AND posting_seq IS NOT NULL
            AND posted_at IS NOT NULL AND posted_by IS NOT NULL)
     OR (posting_status = 'DRAFT'
            AND hash_checksum IS NULL AND posting_seq IS NULL
            AND posted_at IS NULL AND posted_by IS NULL))
);

-- ---------------------------------------------------------------
-- 3. journal_lines
-- ---------------------------------------------------------------
CREATE TABLE journal_lines (
    line_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    header_id   BIGINT NOT NULL REFERENCES journal_headers(header_id)  ON DELETE RESTRICT,
    account_id  INT    NOT NULL REFERENCES chart_of_accounts(account_id) ON DELETE RESTRICT,
    debit       NUMERIC(18,2) NOT NULL DEFAULT 0,
    credit      NUMERIC(18,2) NOT NULL DEFAULT 0,
    CONSTRAINT ck_jl_debit_nonneg  CHECK (debit  >= 0),
    CONSTRAINT ck_jl_credit_nonneg CHECK (credit >= 0),
    CONSTRAINT ck_jl_not_both_zero CHECK (NOT (debit = 0 AND credit = 0)),
    -- tambahan: satu baris hanya boleh satu sisi (debit ATAU kredit)
    CONSTRAINT ck_jl_one_side      CHECK (debit = 0 OR credit = 0)
);
CREATE INDEX ix_jl_header  ON journal_lines(header_id);
CREATE INDEX ix_jl_account ON journal_lines(account_id);

-- ---------------------------------------------------------------
-- 4. Asas berpasangan: total debit = total kredit, ditegakkan di DATABASE
--    (bukan di frontend). Constraint trigger DEFERRED -> dicek saat COMMIT,
--    sehingga baris jurnal boleh dimasukkan satu per satu di dalam transaksi.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_assert_balanced(p_header_id BIGINT, p_force BOOLEAN DEFAULT FALSE) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT; v_dr NUMERIC; v_cr NUMERIC; v_n INT;
BEGIN
    SELECT posting_status INTO v_status FROM journal_headers WHERE header_id = p_header_id;
    IF NOT FOUND THEN RETURN; END IF;
    IF v_status <> 'POSTED' AND NOT p_force THEN RETURN; END IF;   -- DRAFT boleh belum seimbang
    SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*)
      INTO v_dr, v_cr, v_n
      FROM journal_lines WHERE header_id = p_header_id;
    IF v_n < 2 THEN
        RAISE EXCEPTION 'Jurnal % harus memiliki minimal 2 baris (ada %)', p_header_id, v_n
              USING ERRCODE = 'check_violation';
    END IF;
    IF v_dr <> v_cr THEN
        RAISE EXCEPTION 'Jurnal % tidak seimbang: debit % <> kredit %', p_header_id, v_dr, v_cr
              USING ERRCODE = 'check_violation';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION trg_check_balance() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'journal_lines' THEN
        IF TG_OP IN ('INSERT','UPDATE') THEN PERFORM fn_assert_balanced(NEW.header_id); END IF;
        IF TG_OP IN ('DELETE','UPDATE')  THEN PERFORM fn_assert_balanced(OLD.header_id); END IF;
    ELSE
        PERFORM fn_assert_balanced(NEW.header_id);
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER ctrg_balance_lines
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_check_balance();

CREATE CONSTRAINT TRIGGER ctrg_balance_headers
    AFTER INSERT OR UPDATE ON journal_headers
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_check_balance();
