@tool
extends Control

var inspection_calls := 0
@export var custom_secret: String:
	get:
		inspection_calls += 1
		return "editor-custom-secret-must-not-be-inspected"


func _get(_property: StringName):
	inspection_calls += 1
	return null


func _get_property_list() -> Array[Dictionary]:
	inspection_calls += 1
	return []


func _get_minimum_size() -> Vector2:
	inspection_calls += 1
	return Vector2.ZERO


@warning_ignore("native_method_override")
func get_anchor(_side: int) -> float:
	inspection_calls += 1
	return 99.0


@warning_ignore("native_method_override")
func get_offset(_side: int) -> float:
	inspection_calls += 1
	return 99.0


@warning_ignore("native_method_override")
func get_child_count(_include_internal: bool = false) -> int:
	inspection_calls += 1
	return 999
