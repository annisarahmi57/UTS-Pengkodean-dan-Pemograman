// Pola aplikasi: transaksi SERIALIZABLE + retry otomatis pada SQLSTATE 40001 / 40P01
const { Pool } = require('pg');
const pool = new Pool({ host: process.env.PGHOST, port: process.env.PGPORT, user: process.env.PGUSER, database: process.env.PGDATABASE });

async function sellSerializable(itemId, qty, maxRetry = 5) {
  for (let attempt = 1; attempt <= maxRetry; attempt++) {
    const c = await pool.connect();
    try {
      await c.query('BEGIN ISOLATION LEVEL SERIALIZABLE');
      const { rows } = await c.query('SELECT stock_qty FROM inventory_items WHERE item_id = $1', [itemId]);
      if (!rows.length || rows[0].stock_qty < qty) throw Object.assign(new Error('STOK_TIDAK_CUKUP'), { business: true });
      await new Promise(r => setTimeout(r, 300));               // simulasi proses kasir (memperlebar jendela balapan)
      await c.query("INSERT INTO inventory_transactions(item_id, trx_type, qty) VALUES ($1,'SALE',$2)", [itemId, qty]);
      await c.query('COMMIT');
      return { ok: true, attempt };
    } catch (e) {
      await c.query('ROLLBACK').catch(() => {});
      if (['40001', '40P01'].includes(e.code) && attempt < maxRetry) continue;   // konflik serialisasi -> ulangi
      return { ok: false, attempt, error: e.business ? e.message : (e.message || '').split('\n')[0] };
    } finally { c.release(); }
  }
}
module.exports = { sellSerializable };
if (require.main === module) {
  Promise.all([sellSerializable('BRG001', 1), sellSerializable('BRG001', 1)])
    .then(r => { console.log(JSON.stringify(r)); return pool.end(); });
}
