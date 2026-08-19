// WebSocket auth test script
// Usage: node scripts/test_ws_auth.js

const token = process.argv[2] || "";
const characterId = process.argv[3] || "2719";

if (!token) {
    console.log("Usage: node scripts/test_ws_auth.js <token> <characterId>");
    console.log("First get a token from: POST http://localhost:8080/api/login");
    process.exit(1);
}

const WebSocket = require('ws');

console.log(`Token: ${token.substring(0, 16)}...`);
console.log(`Character: ${characterId}`);
console.log(`Connecting to ws://localhost:8787/`);

const ws = new WebSocket('ws://localhost:8787/');

ws.on('open', () => {
    console.log('WS connected');
    const authMsg = JSON.stringify({
        t: "auth-world-5",
        token: token,
        character: parseInt(characterId),
        clientSeed: "",
        timerWire: 2
    });
    console.log('Sending:', authMsg);
    ws.send(authMsg);
});

ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    console.log('Received:', JSON.stringify(msg, null, 2));
    if (msg.t === 'hello') {
        console.log('\n=== AUTH SUCCESS ===');
        console.log('PID:', msg.pid);
        console.log('Name:', msg.name);
        console.log('Class:', msg.cls);
        console.log('Realm:', msg.realm);
        ws.close();
    } else if (msg.t === 'error') {
        console.log('\n=== AUTH FAILED ===');
        console.log('Error:', msg.error);
        ws.close();
    }
});

ws.on('error', (err) => {
    console.error('WS error:', err.message);
});

ws.on('close', (code, reason) => {
    console.log('WS closed:', code);
    process.exit(0);
});

setTimeout(() => {
    console.log('Timeout');
    ws.close();
    process.exit(1);
}, 15000);
