#!/usr/bin/env bash
# Membangun ulang database uji dan menjalankan seluruh skenario uji
export PGHOST=${PGHOST:-localhost}
for t in 90_test_soal1 91_test_soal2 92_test_soal3 93_test_privileges; do
  dropdb --if-exists uts_test; createdb uts_test
  for f in 01_schema.sql 02_audit_immutability_rpc.sql 03_inventory.sql; do psql -d uts_test -q -v ON_ERROR_STOP=1 -f $f; done
  echo "######## $t"; psql -d uts_test -q -f $t.sql 2>&1
done
