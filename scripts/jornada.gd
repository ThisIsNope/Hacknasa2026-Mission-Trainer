extends Node
## Jornada diaria: una lista de misiones (eventos reales de la NASA de los últimos días,
## iguales para todas las salas) que se lanzan una tras otra. Al terminar todas se
## manda el resultado al relay, que guarda la jornada y calcula el bono.
##
## La crea ConexionMCP. Las misiones llegan del relay ({"tipo": "jornada", ...}) o del
## comando MCP "iniciar_dia" con una lista propia.
## Cada misión es un diccionario como los de EventosNasa.lanzar() más "mision_id" y "titulo".

signal terminada(resumen: Dictionary)

const PAUSA_INICIAL := 12.0   # segundos para leer las misiones y tomar el soplete
const PAUSA_ENTRE := 20.0     # descanso entre misiones
const PAUSA_FINAL := 4.0      # después de la última, antes del resumen
const COLOR_AVISO := Color(1.0, 0.75, 0.25)

var fecha := ""
var misiones: Array = []
var resultados: Dictionary = {}     # mision_id -> {"resultado", "dano", "tiempo"}
var indice := -1                    # misión en curso (o la última que se lanzó)
var activa := false
var pantalla: CanvasLayer

var _espera := 0.0
var _aviso_dado := false
var _inicio_ms := 0
var _hud_ref: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE   # si el juego se pausa, la jornada también
	pantalla = load("res://scripts/pantalla_dia.gd").new()
	pantalla.name = "PantallaDia"
	add_child(pantalla)
	_conectar_eventos.call_deferred()   # EventosNasa se carga después de ConexionMCP


func _conectar_eventos() -> void:
	var eventos := get_node_or_null("/root/EventosNasa")
	if eventos and not eventos.evento_terminado.is_connected(_on_evento_terminado):
		eventos.evento_terminado.connect(_on_evento_terminado)


## Empieza la jornada. paquete: {"fecha": "2026-11-15", "misiones": [...]}
func iniciar(paquete: Dictionary) -> bool:
	var lista = paquete.get("misiones")
	if not (lista is Array):
		return false
	var limpias: Array = []
	for m in lista:
		if m is Dictionary and str(m.get("tipo", "")) != "":
			var copia: Dictionary = m.duplicate(true)
			if str(copia.get("mision_id", "")) == "":
				copia["mision_id"] = "m%d" % (limpias.size() + 1)
			if str(copia.get("titulo", "")) == "":
				copia["titulo"] = "Evento %s" % copia["tipo"]
			limpias.append(copia)
		if limpias.size() >= 8:
			break
	if limpias.is_empty():
		return false

	fecha = str(paquete.get("fecha", Time.get_date_string_from_system(true)))
	misiones = limpias
	resultados = {}
	indice = -1
	activa = true
	_espera = PAUSA_INICIAL
	_aviso_dado = false
	_inicio_ms = Time.get_ticks_msec()
	_hud_ref = null
	_sincronizar_hud()
	pantalla.mostrar_inicio(fecha, misiones, PAUSA_INICIAL)
	return true


## La sala ya completó la jornada de hoy: solo se avisa (repetirla no suma puntos).
func avisar_completada(paquete: Dictionary) -> void:
	var previa = paquete.get("previa")
	var texto := "Vuelve mañana para una jornada nueva."
	if previa is Dictionary:
		texto = "Superaste %d de %d misiones (+%d pts de bono). Vuelve mañana." % [
			int(previa.get("superadas", 0)), int(previa.get("misiones", 0)), int(previa.get("bono", 0))]
	fecha = str(paquete.get("fecha", ""))
	pantalla.mostrar_aviso("JORNADA DE HOY COMPLETADA", texto)


func cancelar() -> void:
	if not activa:
		return
	activa = false
	var eventos := get_node_or_null("/root/EventosNasa")
	if eventos and not eventos.activo.is_empty() and str(eventos.activo.get("mision_id", "")) != "":
		eventos.terminar("cancelado")
	_hud("Jornada cancelada", Color.WHITE, 3.0)


## Respuesta del relay al guardar la jornada: {"bono": 420, "repetida": false}
func poner_bono(datos: Dictionary) -> void:
	pantalla.poner_bono(datos.get("bono"), bool(datos.get("repetida", false)))


func _process(delta: float) -> void:
	if not activa:
		return
	_sincronizar_hud()
	var eventos := get_node_or_null("/root/EventosNasa")
	if eventos == null or not eventos.activo.is_empty():
		return   # hay un evento en curso (de la jornada o lanzado por Claude)
	_espera -= delta
	var siguiente := indice + 1
	if not _aviso_dado and _espera <= 5.0 and siguiente < misiones.size() and indice >= 0:
		_aviso_dado = true
		_hud("Siguiente misión en 5 s: %s" % misiones[siguiente]["titulo"], COLOR_AVISO, 4.0)
	if _espera <= 0.0:
		_lanzar_siguiente()


func _lanzar_siguiente() -> void:
	indice += 1
	_aviso_dado = false
	if indice >= misiones.size():
		_terminar()
		return
	var m: Dictionary = misiones[indice]
	var eventos := get_node_or_null("/root/EventosNasa")
	var r: Dictionary = eventos.lanzar(m) if eventos else {"error": "sin EventosNasa"}
	if r.has("error"):
		push_warning("[Jornada] No se pudo lanzar %s: %s" % [m["mision_id"], r["error"]])
		resultados[m["mision_id"]] = {"resultado": "error", "dano": 0.0, "tiempo": 0.0}
		_marcar_tarea(m["mision_id"], "error")
		_espera = 1.0


func _on_evento_terminado(r: Dictionary) -> void:
	if not activa or indice < 0 or indice >= misiones.size():
		return
	var id: String = misiones[indice]["mision_id"]
	if str(r.get("mision_id", "")) != id or resultados.has(id):
		return
	var res := str(r.get("resultado", ""))
	resultados[id] = {
		"resultado": res,
		"dano": float(r.get("dano_recibido_pct", 0.0)),
		"tiempo": float(r.get("tiempo_usado_seg", 0.0)),
	}
	_marcar_tarea(id, res)
	_espera = PAUSA_FINAL if indice + 1 >= misiones.size() else PAUSA_ENTRE


func _terminar() -> void:
	activa = false
	var superadas := 0
	var dano := 0.0
	var detalle := []
	for m in misiones:
		var r: Dictionary = resultados.get(m["mision_id"], {"resultado": "sin_jugar", "dano": 0.0})
		if r["resultado"] == "superado":
			superadas += 1
		dano += float(r.get("dano", 0.0))
		detalle.append({"mision_id": m["mision_id"], "titulo": m["titulo"], "resultado": r["resultado"]})
	var resumen := {
		"fecha": fecha,
		"misiones": misiones.size(),
		"superadas": superadas,
		"dano_total_pct": snappedf(dano, 0.1),
		"tiempo_seg": snappedf((Time.get_ticks_msec() - _inicio_ms) / 1000.0, 0.1),
		"detalle": detalle,
	}
	pantalla.mostrar_fin(resumen)
	terminada.emit(resumen)


## Estado para "¿Cómo va mi misión?" ({} si nunca hubo jornada).
func resumen() -> Dictionary:
	if misiones.is_empty():
		return {}
	var lista := []
	for i in misiones.size():
		var m: Dictionary = misiones[i]
		var estado := "pendiente"
		if resultados.has(m["mision_id"]):
			estado = resultados[m["mision_id"]]["resultado"]
		elif i == indice and activa:
			estado = "en_curso"
		lista.append({"mision_id": m["mision_id"], "titulo": m["titulo"], "estado": estado})
	var r := {"fecha": fecha, "activa": activa, "misiones": lista}
	if activa:
		var eventos := get_node_or_null("/root/EventosNasa")
		if eventos == null or eventos.activo.is_empty():
			r["siguiente_en_seg"] = snappedf(maxf(_espera, 0.0), 0.1)
	return r


# ---------------------------------------------------------------- HUD (panel TAREAS)

## Llena el panel TAREAS con las misiones. Si el HUD cambia (otra escena) se vuelve a llenar.
func _sincronizar_hud() -> void:
	var hud := get_tree().get_first_node_in_group("hud")
	if hud == null or hud == _hud_ref or not hud.has_method("agregar_tarea"):
		return
	_hud_ref = hud
	if hud.has_method("limpiar_tareas"):
		hud.limpiar_tareas()
	for m in misiones:
		hud.agregar_tarea(m["mision_id"], m["titulo"])
	for id in resultados:
		_marcar_tarea(id, resultados[id]["resultado"])


func _marcar_tarea(id: String, resultado: String) -> void:
	if _hud_ref == null or not is_instance_valid(_hud_ref):
		return
	if resultado == "superado":
		_hud_ref.completar_tarea(id)
	elif _hud_ref.has_method("fallar_tarea"):
		_hud_ref.fallar_tarea(id)


func _hud(texto: String, color: Color, segundos: float) -> void:
	var hud := get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("mostrar_mensaje"):
		hud.mostrar_mensaje(texto, color, segundos)
