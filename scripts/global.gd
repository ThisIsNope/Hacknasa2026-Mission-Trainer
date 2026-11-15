extends Node

const OXIGENO_MAX := 125.0
var oxigen := OXIGENO_MAX
var oxygen_decay := 0.12
var partida_terminada := false
var en_curso := true

func reiniciar() -> void:
	oxigen = OXIGENO_MAX
	oxygen_decay = 0.12
	partida_terminada = false
	en_curso = true

func _process(delta: float) -> void:
	if en_curso and not partida_terminada:
		oxigen = maxf(0.0, oxigen - oxygen_decay * delta)
