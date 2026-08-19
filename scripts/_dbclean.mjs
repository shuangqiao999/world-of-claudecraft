import pg from 'pg';
const c = new pg.Client({ connectionString: process.env.DATABASE_URL });
await c.connect();
// 删除压测残留账号 (级联删 characters + auth_tokens)
const r = await c.query(`DELETE FROM accounts WHERE username LIKE 'ld%'`);
console.log('deleted accounts:', r.rowCount);
await c.end();
