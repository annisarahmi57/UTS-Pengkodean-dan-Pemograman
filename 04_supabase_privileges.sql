-- =====================================================================
-- Khusus Supabase: frontend (role anon/authenticated) TIDAK boleh menulis
-- langsung ke tabel; hanya boleh memanggil RPC yang SECURITY DEFINER.
-- =====================================================================
ALTER TABLE journal_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log       ENABLE ROW LEVEL SECURITY;
ALTER TABLE chart_of_accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY read_headers ON journal_headers   FOR SELECT TO authenticated USING (true);
CREATE POLICY read_lines   ON journal_lines     FOR SELECT TO authenticated USING (true);
CREATE POLICY read_audit   ON audit_log         FOR SELECT TO authenticated USING (true);
CREATE POLICY read_coa     ON chart_of_accounts FOR SELECT TO authenticated USING (true);

REVOKE ALL ON journal_headers, journal_lines, audit_log, chart_of_accounts FROM anon, authenticated;
GRANT SELECT ON journal_headers, journal_lines, audit_log, chart_of_accounts TO authenticated;

REVOKE ALL ON FUNCTION rpc_post_cash_disbursement(DATE,TEXT,TEXT,JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION rpc_reverse_journal(BIGINT,TEXT,DATE)            FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_create_and_post_journal(DATE,TEXT,TEXT,JSONB,BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rpc_post_cash_disbursement(DATE,TEXT,TEXT,JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_reverse_journal(BIGINT,TEXT,DATE)            TO authenticated;   -- sebaiknya hanya role supervisor
