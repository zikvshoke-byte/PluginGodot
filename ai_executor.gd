@tool
class_name AIExecutor
extends RefCounted

## Компилирует, анализирует и исполняет динамический GDScript в памяти
## с полным перехватом ошибок/предупреждений и стека вызовов Godot (4.5–4.7+).

var _plugin: EditorPlugin
var _backup: AIBackupManager
var _capture_logger_script: GDScript = null


func _init(plugin: EditorPlugin, backup_manager: AIBackupManager) -> void:
	_plugin = plugin
	_backup = backup_manager


func _prepare_source(raw_code: String) -> Dictionary:
	var code := raw_code.strip_edges()
	var added_lines := 0
	var header := ""

	if not code.begins_with("@tool"):
		header += "@tool\n"
		added_lines += 1

	var has_extends := false
	for line in code.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("extends "):
			has_extends = true
			break
		if s.begins_with("func ") or s.begins_with("var ") or s.begins_with("const "):
			break

	if not has_extends:
		header += "extends RefCounted\n"
		added_lines += 1

	return {
		"source": header + code + "\n",
		"added_lines": added_lines
	}


# ==============================================================================
# ПЕРЕХВАТ НАТИВНЫХ ОШИБОК GODOT (Logger API в Godot 4.5+)
# ==============================================================================

func _start_error_capture() -> Object:
	if not ClassDB.class_exists("Logger"):
		return null
	if not OS.has_method("add_logger") or not OS.has_method("remove_logger"):
		return null

	if _capture_logger_script == null:
		var lcode := """@tool
extends Logger

var _mutex: Mutex = Mutex.new()
var entries: Array[Dictionary] = []

func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var bt_parts: PackedStringArray = []
	for bt in script_backtraces:
		if bt != null and not bt.is_empty():
			bt_parts.append(bt.format().strip_edges())
	_mutex.lock()
	entries.append({
		"function": function,
		"file": file,
		"line": line,
		"code": code,
		"rationale": rationale,
		"error_type": error_type,
		"backtrace": "\\n".join(bt_parts)
	})
	_mutex.unlock()

func _log_message(_message: String, _error: bool) -> void:
	pass

func get_entries_copy() -> Array[Dictionary]:
	_mutex.lock()
	var copy: Array[Dictionary] = entries.duplicate(true)
	_mutex.unlock()
	return copy
"""
		var sc := GDScript.new()
		sc.source_code = lcode
		if sc.reload(true) == OK and sc.can_instantiate():
			_capture_logger_script = sc
		else:
			return null

	var logger_obj: Object = _capture_logger_script.new()
	if logger_obj != null:
		OS.call("add_logger", logger_obj)
	return logger_obj


func _stop_error_capture(logger_obj: Object) -> Array[Dictionary]:
	if logger_obj == null:
		return []
	if OS.has_method("remove_logger"):
		OS.call("remove_logger", logger_obj)
	if logger_obj.has_method("get_entries_copy"):
		var raw: Array = logger_obj.call("get_entries_copy")
		var out: Array[Dictionary] = []
		for item in raw:
			if item is Dictionary:
				out.append(item)
		return out
	return []


func _error_type_label(err_type: int) -> String:
	match err_type:
		1:
			return "ПРЕДУПРЕЖДЕНИЕ"
		2:
			return "ОШИБКА СКРИПТА"
		3:
			return "ОШИБКА ШЕЙДЕРА"
		_:
			return "ОШИБКА ДВИЖКА"


func _get_code_line_preview(file_path: String, line_num: int, raw_code: String, added_lines: int) -> Dictionary:
	var res := {"file_label": file_path, "display_line": line_num, "snippet": ""}
	var is_pasted: bool = (
		file_path.is_empty()
		or file_path.begins_with("<")
		or file_path == "GDScript"
		or file_path.ends_with(".gd::")
	)

	if is_pasted:
		var user_line: int = max(1, line_num - added_lines)
		res["file_label"] = "Вставленный код (run(ai))"
		res["display_line"] = user_line
		var lines := raw_code.strip_edges().split("\n")
		if user_line >= 1 and user_line <= lines.size():
			res["snippet"] = lines[user_line - 1].strip_edges()
	elif file_path.begins_with("res://") and FileAccess.file_exists(file_path) and line_num > 0:
		var lines := FileAccess.get_file_as_string(file_path).split("\n")
		if line_num <= lines.size():
			res["snippet"] = lines[line_num - 1].strip_edges()

	return res


func format_debug_entries(captured: Array[Dictionary], ai_logs: Array, raw_code: String, added_lines: int) -> Dictionary:
	var plain_lines: PackedStringArray = []
	var formatted_items: Array[Dictionary] = []
	var err_num: int = 0
	var real_error_count: int = 0

	# 1. Ошибки из логов самого AIContext (ai.error)
	for entry in ai_logs:
		if entry is Dictionary and str(entry.get("level", "")) == "ERROR":
			err_num += 1
			real_error_count += 1
			var msg: String = str(entry.get("msg", ""))
			var block := "Ошибка #%d [AIContext]: %s" % [err_num, msg]
			plain_lines.append(block)
			formatted_items.append({
				"level": "ERROR",
				"text": block
			})

	# 2. Перехваченные нативные ошибки/предупреждения Godot
	for item in captured:
		var etype: int = int(item.get("error_type", 0))
		var is_warn: bool = (etype == 1)
		if not is_warn:
			real_error_count += 1
		err_num += 1

		var fpath: String = str(item.get("file", ""))
		var fline: int = int(item.get("line", 0))
		var fn: String = str(item.get("function", ""))
		var code_txt: String = str(item.get("code", "")).strip_edges()
		var rat_txt: String = str(item.get("rationale", "")).strip_edges()
		var bt_txt: String = str(item.get("backtrace", "")).strip_edges()

		var info := _get_code_line_preview(fpath, fline, raw_code, added_lines)
		var label := _error_type_label(etype)

		var parts: PackedStringArray = []
		var header := "%s #%d:" % [label, err_num]
		if not str(info["file_label"]).is_empty():
			header += " %s:%d" % [str(info["file_label"]), int(info["display_line"])]
		if not fn.is_empty():
			header += " @ %s()" % fn
		parts.append(header)

		if not rat_txt.is_empty():
			parts.append("  Причина: " + rat_txt)
		if not code_txt.is_empty() and code_txt != rat_txt:
			parts.append("  Детали: " + code_txt)
		if not str(info["snippet"]).is_empty():
			parts.append("  Строка: " + str(info["snippet"]))
		if not bt_txt.is_empty():
			parts.append("  Стек вызовов:\n    " + bt_txt.replace("\n", "\n    "))

		var joined := "\n".join(parts)
		plain_lines.append(joined)
		formatted_items.append({
			"level": "WARN" if is_warn else "ERROR",
			"text": joined
		})

	return {
		"error_count": real_error_count,
		"items": formatted_items,
		"plain_report": "\n\n".join(plain_lines)
	}


# ==============================================================================
# АНАЛИЗ ПЛАНА, ПРОВЕРКА И ИСПОЛНЕНИЕ
# ==============================================================================

func analyze_plan(raw_code: String) -> Dictionary:
	var plan := {
		"scenes": [],
		"files": [],
		"settings": [],
		"deletions": [],
		"warnings": [],
		"node_ops_count": 0
	}

	var lines := raw_code.split("\n")
	for raw_line in lines:
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue

		if (
			"ai.save_scene(" in line
			or "ai.create_scene(" in line
			or "ai.save_current_scene(" in line
			or "ai.edit_scene(" in line
		):
			plan["scenes"].append(line)

		if (
			"ai.write_file(" in line
			or "ai.create_script(" in line
			or "ai.save_resource(" in line
			or "ai.patch_file(" in line
			or "ai.replace_func(" in line
			or "ai.insert_in_file(" in line
			or ("ai.attach_script(" in line and ".gd" in line)
		):
			plan["files"].append(line)

		if (
			"ai.set_project_setting(" in line
			or "ai.set_main_scene(" in line
			or "ai.add_autoload(" in line
			or "ai.add_input_action(" in line
			or "ai.optimize_for_android(" in line
		):
			plan["settings"].append(line)

		if "ai.delete_file(" in line or "ai.remove_node(" in line or "DirAccess.remove" in line:
			plan["deletions"].append(line)

		if "OS.execute" in line or "OS.shell_open" in line:
			plan["warnings"].append("Обнаружен вызов системного API (недоступен или ограничен на Android): " + line)

		if (
			"ai.add_node(" in line
			or "ai.create_box(" in line
			or "ai.create_mesh(" in line
			or "ai.create_csg(" in line
			or "ai.create_physics_" in line
			or "ai.create_ui(" in line
			or "ai.instance_scene(" in line
			or "ai.build_tree(" in line
		):
			plan["node_ops_count"] += 1

	return plan


func validate_code(raw_code: String) -> Dictionary:
	var res := {
		"ok": false,
		"message": "",
		"added_lines": 0,
		"script": null,
		"debug_items": [],
		"debug_report": ""
	}

	if raw_code.strip_edges().is_empty():
		res["message"] = "Поле кода пустое."
		return res

	var prepared := _prepare_source(raw_code)
	res["added_lines"] = prepared["added_lines"]

	var logger_obj: Object = _start_error_capture()
	var script := GDScript.new()
	script.source_code = prepared["source"]
	var err := script.reload(true)
	var captured: Array[Dictionary] = _stop_error_capture(logger_obj)

	var dbg := format_debug_entries(captured, [], raw_code, int(prepared["added_lines"]))
	res["debug_items"] = dbg["items"]
	res["debug_report"] = dbg["plain_report"]

	if err != OK:
		res["message"] = "Ошибка компиляции GDScript (код %d)." % err
		if str(res["debug_report"]).is_empty():
			res["message"] += " Подробности см. во вкладке 'Вывод / Output' (сдвиг: +%d строк)." % int(prepared["added_lines"])
		return res

	if not script.can_instantiate():
		res["message"] = "Скрипт скомпилирован, но не может быть инстанцирован (проверьте ошибки парсинга выше)."
		return res

	var inst = script.new()
	if inst == null:
		res["message"] = "Не удалось создать экземпляр скрипта."
		return res

	if not inst.has_method("run"):
		res["message"] = "В коде не найдена обязательная функция `func run(ai):`."
		return res

	res["ok"] = true
	res["script"] = script
	res["message"] = "Проверка пройдена успешно. Функция run(ai) найдена."
	return res


func execute_code(raw_code: String, safe_mode: bool = true) -> Dictionary:
	var start_ms := Time.get_ticks_msec()
	var check := validate_code(raw_code)

	var report := {
		"ok": false,
		"duration_ms": 0,
		"error": "",
		"logs": [],
		"modified_files": [],
		"pending_deletions": [],
		"ai_context": null,
		"saved_log_name": "",
		"debug_items": check.get("debug_items", []),
		"debug_report": str(check.get("debug_report", "")),
		"error_count": 0
	}

	if not check["ok"]:
		report["error"] = check["message"]
		report["error_count"] = max(1, (report["debug_items"] as Array).size())
		return report

	var ed := _plugin.get_editor_interface() if _plugin else null
	var open_scene := ed.get_edited_scene_root() if ed else null
	_backup.begin_session(open_scene, raw_code)

	var ai := AIContext.new(_plugin, _backup, safe_mode)
	var script: GDScript = check["script"]
	var instance = script.new()

	var logger_obj: Object = _start_error_capture()
	instance.call("run", ai)
	var captured: Array[Dictionary] = _stop_error_capture(logger_obj)

	var dbg := format_debug_entries(captured, ai.logs, raw_code, int(check.get("added_lines", 0)))
	var err_count: int = int(dbg["error_count"])

	var had_changes := ai.scene_modified or not ai.modified_files.is_empty()
	var saved_session: Dictionary = _backup.commit_session(had_changes)

	report["ok"] = (err_count == 0)
	report["error_count"] = err_count
	report["debug_items"] = dbg["items"]
	report["debug_report"] = str(dbg["plain_report"])
	report["duration_ms"] = Time.get_ticks_msec() - start_ms
	report["logs"] = ai.logs
	report["modified_files"] = ai.modified_files
	report["pending_deletions"] = ai.pending_deletions
	report["ai_context"] = ai
	if not saved_session.is_empty():
		report["saved_log_name"] = str(saved_session.get("name", ""))
	return report
