// Entry point for the gateway process when running in sharded mode.
// This process handles WebSocket connections and routes players to zone processes.
// Currently a stub — the full gateway uses ws_auth.ts + Gateway class.
// For now, the zone processes connect directly to each player's WebSocket.

console.log('[gateway] starting...');
// TODO: Full gateway implementation with ws_auth.ts
