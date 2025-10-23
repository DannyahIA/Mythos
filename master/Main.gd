extends Node

# --- Referências ---
@onready var screen_capture: ScreenCapture = null

# --- Configurações ---
const SERVER_URL = "ws://127.0.0.1:3000"
const DEBUG_LOGS := false

# --- Variáveis de Rede ---
var _socket := WebSocketPeer.new()
var webrtc_peers = {} # Armazena as conexões WebRTC por player_id
var _prev_socket_state := -1
var _manual_connected_called := false
var _ws_node: Node = null
var use_websocket_fallback := false
const CHUNK_SIZE := 32 * 1024 # 32KB por chunk (em bytes quando convertido para texto/base64)
var peer_state_timestamps := {} # map player_id -> last_state_change_time (ms)
var peer_state_last_state := {} # map player_id -> last_state
const PEER_STUCK_TIMEOUT := 8.0 # segundos para considerar peer preso em STATE_NEW
var _fallback_queue := [] # filas de chunks prontos para enviar via signaling
var _fallback_timer: Timer = null
var _last_frame_id := 0
const CHUNKS_PER_TICK := 2 # quantos chunks enviar por timeout para reduzir latency
const FALLBACK_CHUNK_INTERVAL_MS := 20 # intervalo entre ticks (ms). menor = menor latency, mais load

# --- Funções do Godot ---

func _ready():
	print("--- Mythos Master App (WebSocket Nativo + WebRTC GDExtension) ---")
	# Tenta obter o nó ScreenCapture de forma segura
	screen_capture = get_node_or_null("ScreenCapture")
	if screen_capture == null:
		printerr("[Main] Nó 'ScreenCapture' não encontrado na cena. Certifique-se de que existe um Node chamado 'ScreenCapture' com o script ScreenCapture.gd ou ajuste o caminho.")
	else:
		screen_capture.frame_captured.connect(_on_frame_captured)

	# Garantir que _process seja executado para fazer polling
	set_process(true)

	# Tenta localizar um node WebSocket provido pelo addon (se houver)
	_ws_node = _find_websocket_node(get_tree().get_root())
	if _ws_node:
		print("[Sinalização] Usando node WebSocket do addon: ", _ws_node.get_path())
		# Se o addon usa WSS por padrão, force ws local para testes
		_ws_node.use_WSS = false
		_ws_node.host = "127.0.0.1:3000"
		_ws_node.route = "/"
		# conecta sinais do node wrapper
		if _ws_node.has_signal("connected"):
			_ws_node.connect("connected", Callable(self, "_on_connected"))
		if _ws_node.has_signal("connect_failed"):
			_ws_node.connect("connect_failed", Callable(self, "_on_disconnected"))
		if _ws_node.has_signal("received"):
			_ws_node.connect("received", Callable(self, "_on_ws_received"))
		# inicia conexão via método do node
		var ok = _ws_node.connect_socket()
		print("[Sinalização] WebSocket addon connect_socket() retornou: ", ok)
	else:
		_connect_to_signaling_server()

	# Checagem rápida: existe suporte a WebRTC (extensão nativa carregada)?
	var has_webrtc = Engine.has_singleton("WebRTCPeerConnection") or typeof(WebRTCPeerConnection) != TYPE_NIL
	if not has_webrtc:
		printerr("[WebRTC] Nenhuma extensão WebRTC detectada. Usando fallback via WebSocket para enviar frames. Certifique-se de que 'webrtc.gdextension' está registrada e as bibliotecas nativas estão disponíveis para sua plataforma. Veja 'project.godot' -> [extensions].")
		use_websocket_fallback = true
	else:
		print("[WebRTC] Extensão WebRTC detectada.")

func _process(_delta):
	var state = _socket.get_ready_state()
	if state != _prev_socket_state:
		print("[Sinalização] Estado WebSocket mudou: ", _prev_socket_state, " -> ", state)
		_prev_socket_state = state

	# Poll sempre que houver suporte e também usamos polling para detectar abertura
	if state == WebSocketPeer.STATE_OPEN:
		_socket.poll()

		# Se os sinais não existirem (logo, não chamariam _on_connected), chamamos manualmente uma vez
		if not _manual_connected_called and not _socket.has_signal("connection_established"):
			_manual_connected_called = true
			print("[Sinalização] detectado WebSocket aberto via polling — chamando manualmente _on_connected()")
			_on_connected()

	# monitorar peers WebRTC e detectar se estão presos em STATE_NEW
	for player_id in webrtc_peers.keys():
		var peer = webrtc_peers[player_id]
		var s = peer.get_connection_state()
		# inicializa timestamp quando o peer aparece
		if not peer_state_timestamps.has(player_id):
			peer_state_timestamps[player_id] = Time.get_ticks_msec()
			peer_state_last_state[player_id] = s
		# se o estado mudou, atualiza timestamp e o estado
		if peer_state_last_state.has(player_id) and s != peer_state_last_state[player_id]:
			peer_state_timestamps[player_id] = Time.get_ticks_msec()
			peer_state_last_state[player_id] = s
		# se estiver em um estado anterior a CONNECTED por muito tempo, faz fallback
		if s < WebRTCPeerConnection.STATE_CONNECTED:
			var t_ms = Time.get_ticks_msec() - peer_state_timestamps[player_id]
			var t = float(t_ms) / 1000.0
			if t >= PEER_STUCK_TIMEOUT:
				print("[WebRTC] Peer ", player_id, " preso no estado ", s, " há ", t, "s — ativando fallback WebSocket para esse peer.")
				# fecha peer e remove
				peer.close()
				webrtc_peers.erase(player_id)
				# liga fallback global para garantia de envio
				use_websocket_fallback = true

# --- Conexão de Sinalização (WebSocket Nativo) ---

func _connect_to_signaling_server():
	print("[Sinalização] Conectando a ", SERVER_URL)
	# Fallback: conecta diretamente usando WebSocketPeer
	var err = _socket.connect_to_url(SERVER_URL)
	print("[Sinalização] connect_to_url() retornou: ", err)
	print("[Sinalização] Estado inicial após connect: ", _socket.get_ready_state())

	if err != OK:
		printerr("[Sinalização] Não foi possível iniciar a conexão.")
		return

	# Faz um poll inicial para acelerar handshake em implementações que precisam de poll
	_socket.poll()
	print("[Sinalização] Poll inicial executado, estado agora: ", _socket.get_ready_state())

	# Inicializa prev state para evitar prints estranhos (será atualizado no _process)
	_prev_socket_state = _socket.get_ready_state()

	# Conecta os sinais do WebSocketPeer (somente se disponíveis na classe atual)
	if _socket.has_signal("connection_established"):
		_socket.connect("connection_established", Callable(self, "_on_connected"))
	else:
		print("[Sinalização] Aviso: signal 'connection_established' não disponível no objeto WebSocketPeer; usando polling para detectar conexão.")

	if _socket.has_signal("connection_closed"):
		_socket.connect("connection_closed", Callable(self, "_on_disconnected"))
	else:
		print("[Sinalização] Aviso: signal 'connection_closed' não disponível no objeto WebSocketPeer.")

	if _socket.has_signal("connection_error"):
		_socket.connect("connection_error", Callable(self, "_on_disconnected")) # Trata erro como desconexão
	else:
		print("[Sinalização] Aviso: signal 'connection_error' não disponível no objeto WebSocketPeer.")

	if _socket.has_signal("data_received"):
		_socket.connect("data_received", Callable(self, "_on_data_received"))
	else:
		print("[Sinalização] Aviso: signal 'data_received' não disponível no objeto WebSocketPeer; usaremos polling para ler pacotes.")

	# helper: encontra node WebSocket do addon (procura recursivamente)
func _find_websocket_node(root: Node) -> Node:
	# procura por custom type 'WebSocket' ou por script do addon
		if typeof(root) == TYPE_OBJECT:
			# check class name
			if root.get_class() == "WebSocket":
				return root
			# check script path if available
			var s = null
			if root.get_script() != null:
				s = str(root.get_script().resource_path)
				if s.find("addons/websocket/WebSocket.gd") != -1:
					return root
		for child in root.get_children():
			var found = _find_websocket_node(child)
			if found:
				return found
		return null

func _send_event(event_name: String, data: Variant = {}):
	# Se um node WebSocket do addon estiver presente, use seus helpers
	if _ws_node != null:
		var dict = {"event": event_name, "data": data}
		print("[Sinalização] (addon) Enviando evento: ", dict)
		_ws_node.send_dict(dict)
		return true
	else:
		if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var payload = {"event": event_name, "data": data}
			var text = JSON.stringify(payload)
			print("[Sinalização] Enviando evento: ", text)
			_socket.send_text(text)
			return true
		else:
			print("[Sinalização] Tentativa de enviar mas socket não está aberto. Estado: ", _socket.get_ready_state())
			return false


func _on_ws_received(data):
	# recebido pode ser um PackedByteArray (via addon) contendo vários pacotes
	# o addon emite uma PackedByteArray com os bytes concatenados; ele também expõe last_received
	if typeof(data) == TYPE_PACKED_BYTE_ARRAY:
		# data é PackedByteArray com todos os bytes; tenta parsear como string
		var s = data.get_string_from_utf8()
		print("[Sinalização] (addon) Pacote recebido (bruto): ", s)
		var json = JSON.new()
		if json.parse(s) == OK:
			var payload = json.get_data()
			if payload.has("event") and payload.has("data"):
				_handle_server_event(payload["event"], payload["data"])
	else:
		print("[Sinalização] (addon) Received callback com tipo: ", typeof(data))

func _on_connected(_arg = null):
	print("[Sinalização] Conectado! Anunciando como Mestre...", _arg)
	_send_event("master_create_room", {"name": "Sala do Mestre"})

func _on_disconnected(_was_clean_close = false): # CORREÇÃO: Adicionado '_' para o parâmetro não utilizado
	print("[Sinalização] Desconectado.")
	# Adicionar lógica de reconexão se necessário

func _on_data_received():
	while _socket.get_available_packet_count() > 0:
			var raw = _socket.get_packet()
			# Tenta obter string primeiro, depois dados binários
			var packet = ""
			if raw is PackedByteArray:
				packet = raw.get_string_from_utf8()
			else:
				# fallback: tenta converter
				packet = String(raw)
			print("[Sinalização] Pacote recebido (bruto): ", packet)
			var json = JSON.new()
			if json.parse(packet) == OK:
				var payload = json.get_data()
				if payload.has("event") and payload.has("data"):
					_handle_server_event(payload["event"], payload["data"])

# --- Fallback queue/timer helpers ---
func _ensure_fallback_timer():
	if _fallback_timer == null:
		_fallback_timer = Timer.new()
		_fallback_timer.wait_time = float(FALLBACK_CHUNK_INTERVAL_MS) / 1000.0
		_fallback_timer.one_shot = false
		_fallback_timer.autostart = false
		_fallback_timer.connect("timeout", Callable(self, "_on_fallback_timer_timeout"))
		add_child(_fallback_timer)

func _on_fallback_timer_timeout():
	# envia até CHUNKS_PER_TICK por timeout para reduzir latency (mais load no servidor)
	if _fallback_queue.size() == 0:
		_fallback_timer.stop()
		return

	var sent = 0
	while sent < CHUNKS_PER_TICK and _fallback_queue.size() > 0:
		var item = _fallback_queue[0]
		_fallback_queue.remove_at(0)
		# prepara payload incluindo o frame_id e remetente (master)
		var payload = {
			"frame_id": item.get("frame_id"),
			"index": item.get("index"),
			"total": item.get("total"),
			"data": item.get("data")
		}
		var ok = _send_event("screen_chunk", payload)
		if not ok:
			# se não foi possível enviar (socket fechado), re-enfileira no começo e tenta reconectar
			_fallback_queue.insert(0, item)
			if DEBUG_LOGS:
				print("[Fallback WS] Falha ao enviar chunk — socket fechado. Re-enfileirando e aguardando conexão.")
			_fallback_timer.stop()
			break
		else:
			if DEBUG_LOGS:
				print("[Fallback WS] Chunk enviado frame=", payload["frame_id"], " idx=", payload["index"], "/", payload["total"])
		sent += 1

# --- Tratamento de Eventos do Servidor ---

func _handle_server_event(event: String, data: Variant):
	match event:
		"player_joined":
			var player_id = data.get("playerId")
			if player_id:
				_start_webrtc_handshake(player_id)
		"player_left":
			var player_id = data.get("playerId")
			if player_id and webrtc_peers.has(player_id):
				print("[WebRTC] Jogador ", player_id, " saiu.")
				var peer = webrtc_peers[player_id]
				peer.close()
				webrtc_peers.erase(player_id)
				if webrtc_peers.is_empty():
					screen_capture.stop()
		"webrtc_answer":
			var sender_id = data.get("senderId")
			var answer_data = data.get("answer")
			if sender_id and webrtc_peers.has(sender_id):
				var peer = webrtc_peers[sender_id]
				print("[WebRTC] Recebido answer de ", sender_id, " (sdp len=", (answer_data["sdp"] or "").length(), ")")
				peer.set_remote_description(answer_data["type"], answer_data["sdp"])
		"webrtc_ice_candidate":
			var sender_id = data.get("senderId")
			var candidate_data = data.get("candidate")
			if sender_id and webrtc_peers.has(sender_id):
				var peer = webrtc_peers[sender_id]
				print("[WebRTC] Recebido ICE candidate de ", sender_id, ": ", candidate_data)
				peer.add_ice_candidate(candidate_data["sdpMid"], candidate_data["sdpMLineIndex"], candidate_data["candidate"])

# --- Lógica WebRTC ---

func _start_webrtc_handshake(player_id: String):
	print("[WebRTC] Iniciando handshake com ", player_id)
	var peer = WebRTCPeerConnection.new()
	
	peer.session_description_created.connect(Callable(self, "_on_offer_created").bind(player_id))
	peer.ice_candidate_created.connect(Callable(self, "_on_ice_candidate_created").bind(player_id))

	webrtc_peers[player_id] = peer
	peer.create_data_channel("screen_share")
	print("[WebRTC] Data channel 'screen_share' criado (local) para ", player_id)
	peer.create_offer()
	print("[WebRTC] Offer criado (create_offer) para ", player_id)
	
	if webrtc_peers.size() == 1:
		screen_capture.start()

func _on_offer_created(type: String, sdp: String, player_id: String):
	print("[WebRTC] Oferta criada para ", player_id)
	var peer = webrtc_peers[player_id]
	peer.set_local_description(type, sdp)
	_send_event("webrtc_offer", {"targetId": player_id, "offer": {"type": type, "sdp": sdp}})

func _on_ice_candidate_created(mid_name: String, index: int, sdp_name: String, player_id: String):
	print("[WebRTC] ICE candidate local criado para ", player_id, ": ", mid_name, index)
	_send_event("webrtc_ice_candidate", {"targetId": player_id, "candidate": {"sdpMid": mid_name, "sdpMLineIndex": index, "candidate": sdp_name}})

# --- Envio de Dados ---

func _on_frame_captured(frame_base64: String):
	# Se WebRTC não disponível, usar fallback via WebSocket enviando em chunks
	if use_websocket_fallback:
		# fragmenta o frame e coloca na fila para envio assíncrono via timer
		_last_frame_id += 1
		var frame_id = str(_last_frame_id)
		var total_len = frame_base64.length()
		var total_chunks = int(ceil(float(total_len) / float(CHUNK_SIZE)))
		var chunk_index = 0
		while chunk_index < total_chunks:
			var start = chunk_index * CHUNK_SIZE
			var end = min(start + CHUNK_SIZE, total_len)
			var chunk = frame_base64.substr(start, end - start)
			# empacota meta dados do chunk na fila
			var queued = {
				"frame_id": frame_id,
				"index": chunk_index,
				"total": total_chunks,
				"data": chunk
			}
			_fallback_queue.append(queued)
			chunk_index += 1
		if DEBUG_LOGS:
			print("[Fallback WS] Enfileirado frame ", frame_id, " com ", total_chunks, " chunks (total chars=", total_len, ")")
		# garante que o timer existe e está rodando
		_ensure_fallback_timer()
		if not _fallback_timer.is_stopped():
			# timer já rodando; fila será esvaziada progressivamente
			pass
		else:
			_fallback_timer.start()
		return

	# Caso contrário, comportamento original via WebRTC
	var packet = ("p#" + frame_base64).to_utf8_buffer()
	for peer in webrtc_peers.values():
		var state = peer.get_connection_state()
		print("[WebRTC] Peer state: ", state)
		if state == WebRTCPeerConnection.STATE_CONNECTED:
			var channel = peer.get_data_channel("screen_share")
			if channel:
				print("[WebRTC] Canal encontrado. ready_state=", channel.get_ready_state())
				if channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
					channel.put_packet(packet)
					print("[WebRTC] Frame enviado pelo data channel (size=", packet.size(), ")")
				else:
					print("[WebRTC] Canal não está aberto ainda.")
			else:
				print("[WebRTC] Canal 'screen_share' não encontrado no peer.")

