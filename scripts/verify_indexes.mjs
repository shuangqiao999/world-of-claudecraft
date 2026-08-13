import pg from 'pg';

const c = new pg.Client({ connectionString: process.env.DATABASE_URL });
await c.connect();

const idx = await c.query(
  "SELECT tablename, indexname FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'idx_%' ORDER BY tablename, indexname"
);
console.log('=== indexes ===');
for (const r of idx.rows) console.log(`  ${r.tablename} :: ${r.indexname}`);

const qs = [
  "SELECT id,name FROM characters WHERE account_id=1 AND realm='Claudemoon' ORDER BY id",
  "SELECT id FROM mail WHERE to_pid=1 AND is_taken=false ORDER BY created_at DESC",
  "SELECT id FROM auctions WHERE sold=false ORDER BY price ASC, id ASC LIMIT 50",
  "SELECT id FROM auctions WHERE seller_pid=1 AND sold=true AND collected=false ORDER BY id",
  "SELECT g.id FROM guild_members gm JOIN guilds g ON gm.guild_id=g.id WHERE gm.character_id=1",
];
for (const q of qs) {
  const e = await c.query('EXPLAIN ' + q);
  console.log('--- ' + q.slice(0, 70));
  console.log(e.rows.map((r) => r['QUERY PLAN']).join('\n'));
}
await c.end();
