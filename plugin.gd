@tool
extends EditorPlugin

const AIDockScript = preload("res://addons/ai_code_executor/ai_dock.gd")

var _dock_instance: Control
var _bottom_button: Button


func _enter_tree() -> void:
    _dock_instance = AIDockScript.new()
    _dock_instance.name = "AIExecutorDock"
    _dock_instance.setup(self)
    _bottom_button = add_control_to_bottom_panel(_dock_instance, "AI Executor")


func _exit_tree() -> void:
    if _dock_instance:
        remove_control_from_bottom_panel(_dock_instance)
        _dock_instance.queue_free()
        _dock_instance = null
    _bottom_button = null
