const { WebSocketServer } = require('ws');
const http = require('http');

const port = 3000;
const host = '0.0.0.0';
const DEBUG_LOGS = false;

// Usamos um servidor HTTP para ter mais controle sobre o handshake
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Servidor de Sinalização Mythos está rodando.');
});

const wss = new WebSocketServer({ server });

let masterSocket = null;
const players = new Map(); // Armazena os objetos de socket por ID

console.log(`--- Servidor de Sinalização Mythos (WebSocket Puro) ---`);
console.log(`Ouvindo em ws://localhost:${port}`);

function broadcast(event, data) {
    wss.clients.forEach(client => {
        if (client.readyState === client.OPEN) {
            client.send(JSON.stringify({ event, data }));
        }
    });
}

wss.on('connection', (ws, req) => {
    // Gerar um ID único para cada conexão
    const clientId = Date.now().toString(36) + Math.random().toString(36).substr(2);
    ws.id = clientId;
    console.log(`[INFO] Cliente conectado: ${ws.id}`);

    if (masterSocket) {
        ws.send(JSON.stringify({ event: 'master_ready', data: { masterId: masterSocket.id } }));
    }

    ws.on('message', (message) => {
        try {
            const { event, data } = JSON.parse(message.toString());
            
            switch (event) {
                case 'master_create_room':
                    console.log(`[SALA] Mestre ${ws.id} criou a sala.`);
                    masterSocket = ws;
                    broadcast('master_ready', { masterId: masterSocket.id });
                    break;

                case 'player_join_room':
                    if (!masterSocket) {
                        ws.send(JSON.stringify({ event: 'error_no_master', data: { message: 'Mestre não encontrado.' } }));
                        return;
                    }
                    console.log(`[SALA] Jogador ${ws.id} entrou.`);
                    players.set(ws.id, ws);
                    masterSocket.send(JSON.stringify({ event: 'player_joined', data: { playerId: ws.id } }));
                    break;
                
                // Retransmissão de mensagens WebRTC
                case 'webrtc_offer':
                case 'webrtc_answer':
                case 'webrtc_ice_candidate':
                    const targetId = data.targetId;
                    const targetSocket = targetId === masterSocket?.id ? masterSocket : players.get(targetId);

                    if (targetSocket) {
                        const relayPayload = { event: event, data: { senderId: ws.id, ...data }};
                        console.log(`[RELAY] ${event} from ${ws.id} -> ${targetId}`);
                        // opcional: imprime sdp ou candidate resumido
                        if (data.offer) console.log('[RELAY] offer sdp len=', (data.offer.sdp || '').length);
                        if (data.answer) console.log('[RELAY] answer sdp len=', (data.answer.sdp || '').length);
                        if (data.candidate) console.log('[RELAY] candidate=', data.candidate.candidate || data.candidate);
                        targetSocket.send(JSON.stringify(relayPayload));
                    }
                    break;
                // Retransmit screen chunks (fallback quando WebRTC não estiver disponível)
                case 'screen_chunk':
                    try {
                        const chunkTargetId = data.targetId;
                        if (DEBUG_LOGS) console.log(`[SCREEN_CHUNK] from ${ws.id} target=${chunkTargetId} index=${data.index} total=${data.total}`);
                        if (chunkTargetId) {
                            const tSocket = chunkTargetId === masterSocket?.id ? masterSocket : players.get(chunkTargetId);
                            if (tSocket && tSocket.readyState === tSocket.OPEN) {
                                tSocket.send(JSON.stringify({ event: 'screen_chunk', data: { senderId: ws.id, ...data }}));
                            }
                        } else {
                            // broadcast to all except sender
                            wss.clients.forEach(client => {
                                if (client.readyState === client.OPEN && client !== ws) {
                                    client.send(JSON.stringify({ event: 'screen_chunk', data: { senderId: ws.id, ...data }}));
                                }
                            });
                        }
                    } catch (e) {
                        console.error('[ERRO] ao retransmitir screen_chunk:', e);
                    }
                    break;
                // ACK quando cliente reconstroi o frame completo
                case 'screen_chunk_ack':
                    try {
                        const targetId = data.targetId;
                        if (DEBUG_LOGS) console.log(`[SCREEN_CHUNK_ACK] from ${ws.id} target=${targetId} frame=${data.frame_id}`);
                        if (targetId) {
                            const tSocket = targetId === masterSocket?.id ? masterSocket : players.get(targetId);
                            if (tSocket && tSocket.readyState === tSocket.OPEN) {
                                tSocket.send(JSON.stringify({ event: 'screen_chunk_ack', data: { senderId: ws.id, frame_id: data.frame_id } }));
                            }
                        } else {
                            // broadcast ACK to all except sender
                            wss.clients.forEach(client => {
                                if (client.readyState === client.OPEN && client !== ws) {
                                    client.send(JSON.stringify({ event: 'screen_chunk_ack', data: { senderId: ws.id, frame_id: data.frame_id } }));
                                }
                            });
                        }
                    } catch (e) {
                        console.error('[ERRO] ao retransmitir screen_chunk_ack:', e);
                    }
                    break;
            }
        } catch (e) {
            console.error(`[ERRO] Mensagem inválida de ${ws.id}:`, message.toString());
        }
    });

    ws.on('close', () => {
        console.log(`[INFO] Cliente desconectado: ${ws.id}`);
        if (ws === masterSocket) {
            masterSocket = null;
            players.clear();
            broadcast('master_disconnected', {});
        } else if (players.has(ws.id)) {
            players.delete(ws.id);
            if (masterSocket) {
                masterSocket.send(JSON.stringify({ event: 'player_left', data: { playerId: ws.id } }));
            }
        }
    });
});

server.listen(port, host);

