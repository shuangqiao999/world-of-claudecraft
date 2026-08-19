// Phase 4 Mob AI 测试: dev_give + 战斗
const WebSocket = require('ws');

async function main() {
    const token = process.argv[2], charId = process.argv[3] || "2720";
    if (!token) { console.log("Usage: node test_phase4.cjs <token> <charId>"); process.exit(1); }
    const ws = new WebSocket('ws://localhost:8787/');

    ws.on('open', () => {
        ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
    });

    ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.t === 'hello') {
            console.log('=== AUTH OK ===');
            runTest();
        } else if (msg.t === 'events') {
            msg.list.forEach(ev => {
                if (ev.type === 'mob_spawn') console.log('[Spawn]', ev.name, 'lv='+ev.level);
                else if (ev.type === 'damage') console.log('[Damage] '+ev.amount+' by '+ev.sourceId+' on '+ev.targetId+' kind='+(ev.kind||'hit')+(ev.crit?' CRIT':''));
                else if (ev.type === 'heal2') console.log('[Heal] '+ev.amount+' on '+ev.targetId);
                else if (ev.type === 'death') console.log('[Death] '+ev.entityId);
                else if (ev.type === 'loot') console.log('[Loot]', JSON.stringify(ev.item));
                else if (ev.type === 'combat_engage') console.log('[Combat] mob='+ev.name+' attacks!');
                else console.log('[Event]', ev.type, JSON.stringify(ev));
            });
        }
    });

    function sendCmd(cmdObj) {
        ws.send(JSON.stringify({ t: "cmd", ...cmdObj }));
    }

    async function runTest() {
        console.log('Spawning nearby wolf...');
        sendCmd({ cmd: "dev_give", level: 3 });

        await sleep(1000);
        console.log('Starting auto attack...');
        sendCmd({ cmd: "attack" });

        await sleep(5000);
        console.log('Casting fireball...');
        sendCmd({ cmd: "cast", ability: "fireball" });

        await sleep(5000);
        console.log('You vs the wolf — watching the fight...');
        await sleep(3000);

        sendCmd({ cmd: "stopattack" });
        await sleep(500);

        console.log('=== Phase 4 Complete ===');
        ws.close();
    }

    function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
    ws.on('close', () => { console.log('WS closed'); process.exit(0); });
    ws.on('error', (e) => { console.error('WS err:', e.message); process.exit(1); });
    setTimeout(() => { console.log('Timeout'); ws.close(); }, 30000);
}

main();
