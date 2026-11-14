extends CanvasLayer

var ox = 100
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	ox = 100


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	$Label.text = str(int((Global.oxigen / 125.0) * 100)) + "%"
