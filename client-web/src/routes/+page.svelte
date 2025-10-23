<script>
	import { onMount, onDestroy } from 'svelte';

	const SERVER_URL = 'ws://localhost:3000';
	let socket;
	let peerConnection;
	
	// Estado da UI
	let status = 'Desconectado';
	let masterId = null;
	let myId = null; // O servidor agora não nos dá um ID, então não sabemos
	let isInRoom = false;
	let logs = [];
	let playerName = `Jogador_${Math.floor(Math.random() * 1000)}`;
	let screenImageSrc = '';
	// Buffer para reconstruir chunks por sender -> frame_id
	let screenBuffers = {};
	const CHUNK_TIMEOUT_MS = 3000; // descarta frames incompletos após 3s

	function addLog(message, type = 'info') {
		const timestamp = new Date().toLocaleTimeString();
		logs = [...logs, { timestamp, message, type }];
	}
	
	function sendEvent(event, data = {}) {
		if (socket && socket.readyState === WebSocket.OPEN) {
			const payload = JSON.stringify({ event, data });
			socket.send(payload);
		}
	}

	async function createPeerConnection(targetId) {
		addLog(`[WEBRTC] Criando peer connection para ${targetId}...`, 'webrtc');
		peerConnection = new RTCPeerConnection();

		peerConnection.onicecandidate = (event) => {
			if (event.candidate) {
				sendEvent('webrtc_ice_candidate', {
					targetId: targetId,
					candidate: event.candidate.toJSON()
				});
			}
		};
		
		peerConnection.ondatachannel = (event) => {
			const channel = event.channel;
			addLog(`[WEBRTC] Canal '${channel.label}' recebido!`, 'success');
			if (channel.label === 'screen_share') {
				channel.onmessage = async (msgEvent) => {
					// Aceita string, ArrayBuffer ou Blob e converte para texto antes de processar
					let data = msgEvent.data;
					if (data instanceof ArrayBuffer) {
						const decoder = new TextDecoder();
						data = decoder.decode(new Uint8Array(data));
					} else if (data instanceof Blob) {
						data = await data.text();
					}
					if (typeof data === 'string' && data.startsWith('p#')) {
						screenImageSrc = "data:image/jpeg;base64," + data.substring(2);
					}
				};
			}
		};
	}
	
	onMount(() => {
		addLog('Conectando ao servidor...');
		socket = new WebSocket(SERVER_URL);

		socket.onopen = () => {
			status = 'Conectado';
			addLog('Conectado com sucesso!', 'success');
		};

		socket.onmessage = async (event) => {
			const payload = JSON.parse(event.data);
			const { event: eventName, data } = payload;

			switch (eventName) {
				case 'master_ready':
					masterId = data.masterId;
					if (!isInRoom) status = 'Mestre encontrado!';
					addLog(`Mestre está pronto na sala com ID: ${masterId}`);
					break;
				case 'master_disconnected':
					masterId = null;
					isInRoom = false;
					status = 'Mestre desconectou.';
					break;
				case 'webrtc_offer':
					addLog(`[WEBRTC] Oferta recebida de ${data.senderId}.`, 'webrtc');
					if (!peerConnection) {
						await createPeerConnection(data.senderId);
					}
					await peerConnection.setRemoteDescription(new RTCSessionDescription(data.offer));
					const answer = await peerConnection.createAnswer();
					await peerConnection.setLocalDescription(answer);
					sendEvent('webrtc_answer', { targetId: data.senderId, answer: answer.toJSON() });
					addLog('[WEBRTC] Resposta (answer) enviada.', 'webrtc');
					break;
				case 'webrtc_ice_candidate':
					if (peerConnection && data.candidate && data.candidate.candidate) {
						try { await peerConnection.addIceCandidate(new RTCIceCandidate(data.candidate)); } catch (e) { console.error('Erro ao adicionar ICE candidate:', e); }
					}
					break;
				case 'screen_chunk':
					// data: { senderId, frame_id, index, total, data }
					try {
						// Avoid UI log for every chunk (heavy). Keep console.debug for devs.
						console.debug(`[SCREEN] chunk recv idx=${data.index} total=${data.total} from=${data.senderId} frame=${data.frame_id}`);
						const sid = data.senderId || 'unknown';
						const fid = data.frame_id || '0';
						// init structures: screenBuffers[sid] -> map of frame_id -> buffer
						if (!screenBuffers[sid]) screenBuffers[sid] = {};
						if (!screenBuffers[sid][fid]) {
							screenBuffers[sid][fid] = { total: data.total, chunks: [], received: 0, timer: null };
							// start timeout to discard incomplete frames
							screenBuffers[sid][fid].timer = setTimeout(() => {
								console.warn('Chunk timeout for frame', fid, 'from', sid, '- discarding');
								if (screenBuffers[sid] && screenBuffers[sid][fid]) {
									clearTimeout(screenBuffers[sid][fid].timer);
									delete screenBuffers[sid][fid];
								}
							}, CHUNK_TIMEOUT_MS);
						}
						const buf = screenBuffers[sid][fid];
						// only count when first time this index is filled
						if (buf.chunks[data.index] === undefined) {
							buf.chunks[data.index] = data.data;
							buf.received += 1;
						}
						// verifica se completos
						if (buf.received === buf.total) {
							// assemble
							const joined = buf.chunks.join('');
							screenImageSrc = 'data:image/jpeg;base64,' + joined;
							// clear timeout and buffer
							clearTimeout(buf.timer);
							delete screenBuffers[sid][fid];
							// send ACK back to master via signaling server (small UI log)
							addLog(`[SCREEN] Frame ${fid} complete from ${sid} — enviando ACK`, 'webrtc');
							sendEvent('screen_chunk_ack', { targetId: sid, frame_id: fid });
						}
					} catch (e) {
						console.error('Erro ao processar screen_chunk:', e);
					}
					break;
			}
		};

		socket.onclose = () => { status = 'Desconectado'; masterId = null; isInRoom = false; addLog('Conexão perdida.', 'error'); };
		socket.onerror = (error) => { addLog('Erro de conexão.', 'error'); console.error("WebSocket Error:", error); };
	});

	onDestroy(() => { if (socket) socket.close(); });

	function joinRoom() {
		if (masterId) {
			addLog('Enviando pedido para entrar na sala...');
			sendEvent('player_join_room', { name: playerName });
			isInRoom = true;
			status = `Na sala com o Mestre`;
		}
	}
</script>

<main class="container">
	<header>
		<h1>Mythos VTT - Cliente Web</h1>
		<p class="status">Status: <strong>{status}</strong></p>
	</header>
	
	<div class="screen-container">
		{#if screenImageSrc}
			<img src={screenImageSrc} alt="Tela do Mestre" />
		{:else}
			<div class="placeholder">Aguardando a tela do Mestre...</div>
		{/if}
	</div>

	<div class="controls">
		<input type="text" bind:value={playerName} placeholder="Seu nome" />
		<button on:click={joinRoom} disabled={!masterId || isInRoom}>
			{#if !masterId}Aguardando Mestre...{:else if isInRoom}Na Sala{:else}Entrar na Sala{/if}
		</button>
	</div>

	<div class="log-container">
		<h2>Log de Eventos</h2>
		<div class="logs">
			{#each logs as log, i (i)}
				<p class="log-entry {log.type}"><span class="timestamp">{log.timestamp}</span>{log.message}</p>
			{/each}
		</div>
	</div>
</main>

<style>
	:root { --bg-color: #1a1a1a; --text-color: #e0e0e0; --primary-color: #bb86fc; --surface-color: #2c2c2c; --border-color: #444; --success-color: #03dac6; --error-color: #cf6679; }
	.container { max-width: 800px; margin: 2rem auto; padding: 2rem; background-color: var(--bg-color); color: var(--text-color); font-family: sans-serif; border-radius: 8px; }
	header { text-align: center; margin-bottom: 2rem; }
	h1 { color: var(--primary-color); }
	.status { font-size: 1.1rem; padding: 0.5rem; background-color: var(--surface-color); border-radius: 4px; }
	.controls { display: flex; gap: 1rem; margin-bottom: 2rem; }
	input { flex-grow: 1; padding: 0.8rem; background-color: var(--surface-color); border: 1px solid var(--border-color); color: var(--text-color); border-radius: 4px; }
	button { padding: 0.8rem 1.5rem; border: none; background-color: var(--primary-color); color: #000; font-weight: bold; cursor: pointer; border-radius: 4px; transition: background-color 0.2s; }
	button:hover:not(:disabled) { background-color: #a063f0; }
	button:disabled { background-color: #555; cursor: not-allowed; }
	.log-container { background-color: var(--surface-color); padding: 1rem; border-radius: 4px; }
	.logs { height: 300px; overflow-y: auto; padding: 0.5rem; background-color: #121212; border-radius: 4px; font-family: monospace; }
	.log-entry { margin: 0.25rem 0; }
	.timestamp { color: #888; margin-right: 0.5rem; }
	.log-entry.success { color: var(--success-color); }
	.log-entry.error { color: var(--error-color); }
	.log-entry.webrtc { color: #f0e68c; }
	.screen-container { width: 100%; aspect-ratio: 16 / 9; background-color: #000; margin-bottom: 2rem; border-radius: 4px; display: flex; align-items: center; justify-content: center; border: 1px solid var(--border-color); }
	.screen-container img { width: 100%; height: 100%; object-fit: contain; }
	.placeholder { color: #888; }
</style>

