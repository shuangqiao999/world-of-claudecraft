// Phase 3 战斗测试: 登录 + 生成Mob + 攻击 + 技能
const WebSocket = require('ws');

async function main() {
    const token = process.argv[2];
    const charId = process.argv[3] || "2720";
    if (!token) { console.log("Usage: node test_phase3.cjs <token> <charId>"); process.exit(1); }

    const ws = new WebSocket('ws://localhost:8787/');
    let pid = 0, seq = 0, step = 0;

    ws.on('open', () => {
        console.log('WS connected');
        ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
    });

    ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());

        if (msg.t === 'hello') {
            pid = msg.pid;
            console.log(`=== AUTH OK: pid=${pid} ===\n`);
            runTests();
        } else if (msg.t === 'events') {
            console.log('Events:', JSON.stringify(msg.list));
        } else if (msg.t === 'error') {
            console.log('ERROR:', msg.error);
            ws.close();
        }
    });

    function sendCmd(cmdObj) {
        ws.send(JSON.stringify({ t: "cmd", ...cmdObj }));
    }

    async function runTests() {
        // Step 1: Enable dev commands + spawn mob
        console.log('--- Step 1: Spawn test mob ---');
        sendCmd({ cmd: "dev_give", level: 5 });
        await sleep(500);

        // Step 2: Target nearest (just attack the spawned mob)
        console.log('--- Step 2: Auto attack ---');
        sendCmd({ cmd: "attack" });
        await sleep(3000);

        // Step 3: Cast fireball
        console.log('--- Step 3: Cast fireball ---');
        sendCmd({ cmd: "cast", ability: "fireball" });
        await sleep(3000);

        // Step 4: Cast heal
        console.log('--- Step 4: Cast heal ---');
        sendCmd({ cmd: "cast", ability: "heal" });
        await sleep(3000);

        // Step 5: Stop attack
        console.log('--- Step 5: Stop attack ---');
        sendCmd({ cmd: "stopattack" });
        await sleep(1000);

        console.log('\n=== Phase 3 Test Complete ===');
        ws.close();
    }

    function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

    ws.on('close', () => { console.log('WS closed'); process.exit(0); });
    ws.on('error', (e) => { console.error('WS error:', e.message); process.exit(1); });
    setTimeout(() => { console.log('Timeout'); ws.close(); }, 25000);
}

main();
