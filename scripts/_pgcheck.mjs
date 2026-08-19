import pg from 'pg';
const c = new pg.Client({ connectionString: process.env.DATABASE_URL });
await c.connect();
const r = await c.query('SHOW max_connections');
const r2 = await c.query('SELECT count(*) n FROM pg_stat_activity');
console.log('max_connections=', r.rows[0].max_connections, 'active=', r2.rows[0].n);
await c.end();
