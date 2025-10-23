class_name ScreenCapture
extends Node

## Emite um sinal a cada quadro capturado, enviando a imagem como uma string Base64.
signal frame_captured(frame_base64)

var _capture_enabled = false

func _process(_delta):
	if not _capture_enabled:
		return
	
	# Aguarda o final do quadro atual para garantir que tudo foi desenhado
	await get_tree().process_frame
	
	# Captura o viewport principal
	var img = get_viewport().get_texture().get_image()
	
	# Converte a imagem para o formato JPG (mais eficiente para streaming)
	var jpg_data = img.save_jpg_to_buffer()
	
	# Codifica os dados binários do JPG para Base64
	var base64_str = Marshalls.raw_to_base64(jpg_data)
	
	# Emite o sinal com a string Base64
	frame_captured.emit(base64_str)

## Inicia a captura de quadros.
func start():
	_capture_enabled = true
	print("[ScreenCapture] Captura iniciada.")

## Para a captura de quadros.
func stop():
	_capture_enabled = false
	print("[ScreenCapture] Captura interrompida.")

