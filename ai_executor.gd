@tool
class_name AIExecutor
extends RefCounted

## Компилирует, анализирует и исполняет динамический GDScript в памяти
## (совместимо со всеми версиями Godot 4.x на Android и Desktop).

var _plugin: EditorPlugin
var _backup: AIBackupManager


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
        "script": null
    }

    if raw_code.strip_edges().is_empty():
        res["message"] = "Поле кода пустое."
        return res

    var prepared := _prepare_source(raw_code)
    res["added_lines"] = prepared["added_lines"]

    var script := GDScript.new()
    script.source_code = prepared["source"]
    var err := script.reload(true)

    if err != OK:
        res["message"] = "Ошибка компиляции GDScript (код %d). Подробности и номер строки см. во вкладке 'Вывод / Output' редактора (учтите сдвиг: +%d строк заголовка)." % [err, prepared["added_lines"]]
        return res

    if not script.can_instantiate():
        res["message"] = "Скрипт скомпилирован, но не может быть инстанцирован (проверьте наличие ошибок парсинга)."
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
        "saved_log_name": ""
    }

    if not check["ok"]:
        report["error"] = check["message"]
        return report

    var ed := _plugin.get_editor_interface() if _plugin else null
    var open_scene := ed.get_edited_scene_root() if ed else null
    _backup.begin_session(open_scene, raw_code)

    var ai := AIContext.new(_plugin, _backup, safe_mode)
    var script: GDScript = check["script"]
    var instance = script.new()

    instance.call("run", ai)

    var has_errors := false
    for entry in ai.logs:
        if entry["level"] == "ERROR":
            has_errors = true

    var had_changes := ai.scene_modified or not ai.modified_files.is_empty()
    var saved_session: Dictionary = _backup.commit_session(had_changes)

    report["ok"] = not has_errors
    report["duration_ms"] = Time.get_ticks_msec() - start_ms
    report["logs"] = ai.logs
    report["modified_files"] = ai.modified_files
    report["pending_deletions"] = ai.pending_deletions
    report["ai_context"] = ai
    if not saved_session.is_empty():
        report["saved_log_name"] = str(saved_session.get("name", ""))
    return report
