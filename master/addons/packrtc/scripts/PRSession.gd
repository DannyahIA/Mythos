extends Node
class_name PRSession

var code: String = ""
var ws_url: String = ""
## Multiplayer peer
var rtc_peer : WebRTCMultiplayerPeer
var peer_id = -1
var peers = []
var connection_list = {}
var ws: WebSocketClient
var webrtc_config = {
	"iceServers": [
		{ "urls": ["stun:stun.l.google.com:19302"] }
	]
}

var _server_connection

## Emit when the peer is ready to go
signal peer_ready(peer: WebRTCMultiplayerPeer)

func _ready() -> void:
	# Connect with PackRTC Websocket
	ws = WebSocketClient.new()
	add_child(ws)
	
	ws.connect_to_url(ws_url)
	ws.connection_established.connect(_on_connection_established)
	ws.text_received.connect(_on_text_received)

func _on_connection_established(peer : WebSocketPeer, protocol : String):
	print("PackRTC Connected!")

func _on_text_received(peer : WebSocketPeer, message):
	var data = JSON.parse_string(message)
	var data_type = data.data_type
	
	if data_type == "offer":
		connection_list[int(data.from)].set_remote_description(data.type, data.sdp)
	
	if data_type == "answer":
		connection_list[int(data.from)].set_remote_description(data.type, data.sdp)
	
	if data_type == "ice":
		connection_list[int(data.from)].add_ice_candidate(data.media, data.index, data._name)
	
	if data_type == "new_connection":
		if data.peer_id != peer_id:
			add_peer(data.peer_id)
	
	if data_type == "initialize":
		peer_id = data.id
		peers = data.peers
		init_rtc()

func init_rtc():
	# Initialize WebRTC
	rtc_peer = WebRTCMultiplayerPeer.new()
	if PackRTC.use_mesh:
		# Mesh connection
		rtc_peer.create_mesh(peer_id)
	else:
		# Server/client connection
		if peer_id == 1:
			rtc_peer.create_server()
		else:
			rtc_peer.create_client(peer_id)
	
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	
	connection_list.clear()
	
	if PackRTC.use_mesh:
		for pid in peers:
			add_peer(pid)
	else:
		init_server_peer()
	
	peer_ready.emit(rtc_peer)
	ws.send_text(JSON.stringify({
		data_type = "ready"
	}))

func _peer_connected(id):
	peers.append(id)

func _peer_disconnected(id):
	peers.erase(id)

func add_peer(pid):
	var connection = WebRTCPeerConnection.new()
	connection.initialize(webrtc_config)
	connection.session_description_created.connect(session_created.bind(connection))
	connection.ice_candidate_created.connect(ice_created.bind(connection))
	connection_list[int(pid)] = connection
	
	if PackRTC.use_mesh:
		rtc_peer.add_peer(connection, pid)
		if peer_id < pid:
			connection.create_offer()
	else:
		if peer_id == 1:
			rtc_peer.add_peer(connection, pid)

func init_server_peer():
	var pid = 1
	var connection = WebRTCPeerConnection.new()
	connection.initialize(webrtc_config)
	connection.session_description_created.connect(session_created.bind(connection))
	connection.ice_candidate_created.connect(ice_created.bind(connection))
	connection_list[int(pid)] = connection
	
	if peer_id != 1:
		rtc_peer.add_peer(connection, pid)
		connection.create_offer()

func session_created(type: String, sdp: String, connection : WebRTCPeerConnection):
	var peer_id = connection_list.find_key(connection)
	connection.set_local_description(type, sdp)
	if type == "offer":
		ws.send_text(JSON.stringify({
			data_type = "offer",
			to = peer_id,
			type = type,
			sdp = sdp
		}))
	else:
		ws.send_text(JSON.stringify({
			data_type = "answer",
			to = peer_id,
			type = type,
			sdp = sdp
		}))

func ice_created(media: String, index: int, _name: String, connection : WebRTCPeerConnection):
	var peer_id = connection_list.find_key(connection)
	ws.send_text(JSON.stringify({
		data_type = "ice",
		to = peer_id,
		media = media,
		index = index,
		_name = _name
	}))
