\set VERBOSITY terse
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
INSERT INTO chart_of_accounts(account_code,account_name,normal_balance,report_class,is_cash) VALUES ('1-1200','Bank','DEBIT','NERACA',TRUE),('6-1100','Beban Listrik','DEBIT','LABA_RUGI',FALSE);
\i 04_supabase_privileges.sql
SET ROLE authenticated;
\echo '--- T4.1 authenticated INSERT langsung ke journal_headers'
INSERT INTO journal_headers(trx_date,reference_no,description) VALUES (current_date,'X','x');
\echo '--- T4.2 authenticated memanggil RPC'
SELECT rpc_post_cash_disbursement(current_date,'KK-9','ok','[{"account_code":"6-1100","debit":5},{"account_code":"1-1200","credit":5}]'::jsonb);
\echo '--- T4.3 authenticated memanggil fungsi internal / UPDATE'
SELECT fn_create_and_post_journal(current_date,'Z','z','[]'::jsonb);
UPDATE journal_headers SET description='hack';
RESET ROLE;
SET ROLE anon;
\echo '--- T4.4 anon membaca'
SELECT count(*) FROM journal_headers;
RESET ROLE;
