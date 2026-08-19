// Phase 5-6 终极测试: 背包/商店/任务/天赋/组队/好友/工会
const WebSocket = require('ws');

async function main() {
    const token = process.argv[2], charId = process.argv[3] || "2720";
    const ws = new WebSocket('ws://localhost:8787/');
    let step = 0;

    ws.on('open', () => {
        ws.send(JSON.stringify({ t: "auth-world-5", token, character: parseInt(charId), clientSeed: "", timerWire: 2 }));
    });

    ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());
        if (msg.t === 'hello') { console.log('AUTH OK pid='+msg.pid); runTest(); }
        else if (msg.t === 'events') {
            msg.list.forEach(e => {
                if (e.type === 'mob_spawn') return;
                if (e.type === 'damage' || e.type === 'heal2') return;
                if (e.type === 'quest_progress') console.log('[Quest] Progress ' + e.questId + ': ' + e.current + '/' + e.required);
                else console.log('[' + e.type + ']', JSON.stringify(e));
            });
        }
    });

    function send(c) { ws.send(JSON.stringify({ t: "cmd", ...c })); }
    async function runTest() {
        // Test 1: Buy from vendor
        console.log('\n--- Test 1: Vendor ---');
        send({ cmd: "buy", itemId: "health_potion" });
        await sleep(300);
        send({ cmd: "buy", itemId: "wooden_sword" });
        await sleep(300);

        // Test 2: Equip item
        console.log('\n--- Test 2: Equip ---');
        send({ cmd: "equip", slot: 1, equipSlot: "mainhand" });
        await sleep(300);

        // Test 3: Accept + complete quest
        console.log('\n--- Test 3: Quest ---');
        send({ cmd: "accept", questId: "test_kill" });
        await sleep(300);
        send({ cmd: "dev_give", level: 1 });
        await sleep(300);
        send({ cmd: "attack" });
        await sleep(4000);  // Wait for mob kill
        send({ cmd: "turnin", questId: "test_kill" });
        await sleep(300);

        // Test 4: Talent
        console.log('\n--- Test 4: Talent ---');
        send({ cmd: "applyTalents", talentId: "w1" });
        await sleep(300);

        // Test 5: Bank
        console.log('\n--- Test 5: Bank ---');
        send({ cmd: "bank_deposit", slot: 0 });
        await sleep(300);
        send({ cmd: "bank_withdraw", slot: 0 });
        await sleep(300);

        // Test 6: Friends
        console.log('\n--- Test 6: Friends ---');
        send({ cmd: "friend_add", target: 1002 });
        await sleep(300);

        // Test 7: Harvest
        console.log('\n--- Test 7: Harvest ---');
        send({ cmd: "harvest_node", nodeType: "herb" });
        await sleep(300);

        console.log('\n=== Phase 5-6 Complete ===');
        ws.close();
    }
    function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
    ws.on('close', () => { console.log('WS closed'); process.exit(0); });
    ws.on('error', (e) => { console.error('WS err:', e.message); process.exit(1); });
    setTimeout(() => { process.exit(0); }, 25000);
}
main();
