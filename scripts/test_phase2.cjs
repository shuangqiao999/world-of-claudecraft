// Phase 2 综合测试: 登录 + 移动 + 聊天
// Usage: node scripts/test_phase2.cjs

const WebSocket = require('ws');

async function main() {
    const token = process.argv[2];
    const charId = process.argv[3] || "2720";

    if (!token) {
        console.log("Usage: node scripts/test_phase2.cjs <token> <characterId>");
        console.log("Get token from: curl -X POST http://localhost:8080/api/login ...");
        process.exit(1);
    }

    const ws = new WebSocket('ws://localhost:8787/');
    let pid = 0;
    let seq = 0;
    let moveTimer;

    ws.on('open', () => {
        console.log('WS connected');
        ws.send(JSON.stringify({
            t: "auth-world-5", token, character: parseInt(charId),
            clientSeed: "", timerWire: 2
        }));
    });

    ws.on('message', (data) => {
        const msg = JSON.parse(data.toString());

        if (msg.t === 'hello') {
            pid = msg.pid;
            console.log('\n=== HELLO ===');
            console.log(`PID: ${msg.pid}, Name: ${msg.name}, Class: ${msg.cls}`);
            console.log('=== AUTH SUCCESS ===\n');

            // 开始发送移动输入
            console.log('Starting movement test (5 seconds)...');
            moveTimer = setInterval(() => {
                seq++;
                ws.send(JSON.stringify({
                    t: "input",
                    seq: seq,
                    mi: { f: 1, b: 0, tl: 0, tr: 0, sl: 0, sr: 0, j: 0 },
                    facing: 0.5
                }));
            }, 100); // 10Hz input

            // 发送聊天
            setTimeout(() => {
                ws.send(JSON.stringify({
                    t: "cmd", cmd: "chat", text: "Hello from Phase 2 test!",
                    channel: "say"
                }));
                console.log('Sent chat message');
            }, 1500);

            // 停止测试
            setTimeout(() => {
                clearInterval(moveTimer);
                console.log('\n=== Phase 2 Test Complete ===');
                ws.close();
            }, 5000);

        } else if (msg.t === 'snap') {
            // 显示快照摘要
            const ents = msg.ents || [];
            const self = msg.self;
            if (self && self.id) {
                process.stdout.write(`\rTick:${msg.tick} Pos:(${self.x?.toFixed(1)},${self.z?.toFixed(1)}) | Ents:${ents.length}  `);
            }
        } else if (msg.t === 'events') {
            console.log('\nEvents:', JSON.stringify(msg.list));
        } else if (msg.t === 'error') {
            console.log('\nERROR:', msg.error);
            ws.close();
        }
    });

    ws.on('close', () => {
        if (moveTimer) clearInterval(moveTimer);
        console.log('\nWS closed');
        process.exit(0);
    });

    ws.on('error', (err) => {
        console.error('WS error:', err.message);
        process.exit(1);
    });

    setTimeout(() => { console.log('Timeout'); ws.close(); }, 20000);
}

main();
