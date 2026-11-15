extends CSGBox3D

var is_interactable = true

func interact():
	if not is_interactable:
		return
