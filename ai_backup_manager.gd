@tool
class_name AIBackupManager
extends RefCounted

const BACKUP_ROOT := "res://.ai_executor_backups"
const HISTORY_FILE := "res://.ai_executor_backups/history.json"

var _plugin: EditorPlugin
var _sessions: Array[Dictionary] = []
var _next_number: int = 1
var _current_session: Dictionary = {}
var _live_created_nodes: Dictionary = {}


func _init(plugin: EditorPlugin = null) -> void:
    _plugin = plugin
    _ensure_backup_root()
    _load_history()


func _get_editor() -> EditorInterface:
    return _plugin.get_editor_interface() if _plugin else null


func _ensure_backup_root() -> void:
    if not DirAccess.dir_exists_absolute(BACKUP_ROOT):
        DirAccess.make_dir_recursive_absolute(BACKUP_ROOT)
    var gdignore_path := BACKUP_ROOT + "/.gdignore"
    if not FileAccess.file_exists(gdignore_path):
        var f := FileAccess.open(gdignore_path, FileAccess.WRITE)
        if f:
            f.store_string("")
            f.close()


func begin_session(open_scene_root: Node = null, raw_code: String = "") -> void:
    _ensure_backup_root()
    _next_number = _sessions.size() + 1
    var stamp: String = str(Time.get_unix_time_from_system()).replace(".", "_")
    var session_dir: String = "%s/session_%s" % [BACKUP_ROOT, stamp]
    DirAccess.make_dir_recursive_absolute(session_dir)

    var fs_before: Dictionary = _snapshot_project_fs()
    var dt: String = Time.get_datetime_string_from_system(false, true)

    _current_session = {
        "id": stamp,
        "number": _next_number,
        "name": str(_next_number),
        "is_renamed": false,
        "timestamp": dt,
        "code": raw_code,
        "dir": session_dir,
        "fs_before_files": fs_before["files"],
        "fs_before_dirs": fs_before["dirs"],
        "created_files": [],
        "created_dirs": [],
        "backed_up_files": {},
        "deleted_files": {},
        "project_settings": {},
        "open_scene_path": "",
        "open_scene_backup": "",
        "open_scene_modified": false
    }
    _live_created_nodes[stamp] = []

    if open_scene_root != null and open_scene_root.scene_file_path != "":
        var scene_path: String = _normalize_path(open_scene_root.scene_file_path)
        _current_session["open_scene_path"] = scene_path
        var packed := PackedScene.new()
        if packed.pack(open_scene_root) == OK:
            var snap_path: String = session_dir + "/_open_scene_snapshot.tscn"
            if ResourceSaver.save(packed, snap_path) == OK:
                _current_session["open_scene_backup"] = snap_path


func mark_open_scene_modified() -> void:
    if _current_session.is_empty():
        return
    _current_session["open_scene_modified"] = true


func record_before_write(res_path: String) -> void:
    if _current_session.is_empty():
        return
    var norm: String = _normalize_path(res_path)
    if norm.begins_with(BACKUP_ROOT):
        return

    if norm == str(_current_session.get("open_scene_path", "")):
        _current_session["open_scene_modified"] = true

    var backed: Dictionary = _current_session["backed_up_files"]
    var created: Array = _current_session["created_files"]

    if FileAccess.file_exists(norm):
        if not backed.has(norm) and not created.has(norm):
            var bpath: String = _copy_to_backup(norm)
            if bpath != "":
                backed[norm] = bpath
    else:
        if not created.has(norm):
            created.append(norm)


func record_created_dir(dir_path: String) -> void:
    if _current_session.is_empty():
        return
    var norm: String = _normalize_path(dir_path).trim_suffix("/")
    if norm == "res://" or norm == "res:" or norm.begins_with(BACKUP_ROOT):
        return
    if not DirAccess.dir_exists_absolute(norm):
        var cdirs: Array = _current_session["created_dirs"]
        if not cdirs.has(norm):
            cdirs.append(norm)


func record_created_node(node: Node) -> void:
    if _current_session.is_empty() or node == null:
        return
    var sid: String = str(_current_session["id"])
    if not _live_created_nodes.has(sid):
        _live_created_nodes[sid] = []
    var arr: Array = _live_created_nodes[sid]
    arr.append(weakref(node))


func record_before_delete(res_path: String) -> void:
    if _current_session.is_empty():
        return
    var norm: String = _normalize_path(res_path)
    if not FileAccess.file_exists(norm):
        return
    var dels: Dictionary = _current_session["deleted_files"]
    var backed: Dictionary = _current_session["backed_up_files"]
    if not dels.has(norm) and not backed.has(norm):
        var bpath: String = _copy_to_backup(norm)
        if bpath != "":
            dels[norm] = bpath


func record_project_setting(key: String) -> void:
    if _current_session.is_empty():
        return
    var ps_map: Dictionary = _current_session["project_settings"]
    if ps_map.has(key):
        return
    var existed: bool = ProjectSettings.has_setting(key)
    var encoded_val: String = ""
    if existed:
        var old_val: Variant = ProjectSettings.get_setting(key)
        encoded_val = Marshalls.raw_to_base64(var_to_bytes_with_objects(old_val))
    ps_map[key] = {
        "existed": existed,
        "value_b64": encoded_val
    }


func commit_session(had_changes: bool) -> Dictionary:
    if _current_session.is_empty():
        return {}

    var sid: String = str(_current_session["id"])
    var fs_after: Dictionary = _snapshot_project_fs()
    var before_files: Dictionary = _current_session.get("fs_before_files", {})
    var before_dirs: Dictionary = _current_session.get("fs_before_dirs", {})
    var created_files: Array = _current_session["created_files"]
    var created_dirs: Array = _current_session["created_dirs"]
    var backed_files: Dictionary = _current_session["backed_up_files"]

    for fpath in fs_after["files"].keys():
        var fp: String = str(fpath)
        if not before_files.has(fp):
            if not created_files.has(fp) and not backed_files.has(fp):
                created_files.append(fp)

    for dpath in fs_after["dirs"].keys():
        var dp: String = str(dpath)
        if not before_dirs.has(dp):
            if not created_dirs.has(dp):
                created_dirs.append(dp)

    var open_scene_mod: bool = bool(_current_session.get("open_scene_modified", false))
    var open_scene_path: String = str(_current_session.get("open_scene_path", ""))
    var open_scene_backup: String = str(_current_session.get("open_scene_backup", ""))
    if not open_scene_mod:
        if open_scene_backup != "" and FileAccess.file_exists(open_scene_backup):
            DirAccess.remove_absolute(open_scene_backup)
        open_scene_path = ""
        open_scene_backup = ""

    _current_session.erase("fs_before_files")
    _current_session.erase("fs_before_dirs")

    var live_nodes: Array = _live_created_nodes.get(sid, [])
    var has_ops: bool = (
        not created_files.is_empty()
        or not created_dirs.is_empty()
        or not live_nodes.is_empty()
        or open_scene_mod
        or not backed_files.is_empty()
        or not (_current_session["deleted_files"] as Dictionary).is_empty()
        or not (_current_session["project_settings"] as Dictionary).is_empty()
    )

    var saved_session: Dictionary = {}
    if had_changes or has_ops:
        var assigned_num: int = _sessions.size() + 1
        saved_session = {
            "id": sid,
            "number": assigned_num,
            "name": str(assigned_num),
            "is_renamed": false,
            "timestamp": str(_current_session["timestamp"]),
            "code": str(_current_session["code"]),
            "dir": str(_current_session["dir"]),
            "created_files": created_files.duplicate(),
            "created_dirs": created_dirs.duplicate(),
            "backed_up_files": backed_files.duplicate(true),
            "deleted_files": (_current_session["deleted_files"] as Dictionary).duplicate(true),
            "project_settings": (_current_session["project_settings"] as Dictionary).duplicate(true),
            "open_scene_path": open_scene_path,
            "open_scene_backup": open_scene_backup,
            "open_scene_modified": open_scene_mod
        }
        _sessions.append(saved_session)
        _renumber_sessions()
        _save_history()
    else:
        _live_created_nodes.erase(sid)
        _remove_dir_recursive(str(_current_session["dir"]))

    _current_session = {}
    return saved_session


func has_undo() -> bool:
    return not _sessions.is_empty()


func get_undo_count() -> int:
    return _sessions.size()


func get_sessions() -> Array[Dictionary]:
    return _sessions


func get_session_by_id(session_id: String) -> Dictionary:
    for s in _sessions:
        if str(s.get("id", "")) == session_id:
            return s
    return {}


func rename_session(session_id: String, new_name: String) -> bool:
    var trimmed: String = new_name.strip_edges()
    if trimmed.is_empty():
        return false
    for s in _sessions:
        if str(s.get("id", "")) == session_id:
            s["name"] = trimmed
            s["is_renamed"] = (trimmed != str(s.get("number", 0)))
            _save_history()
            return true
    return false


## Объединяет выбранные логи в один чистый скрипт из актуального состояния файлов на диске (без старых ошибок!)
func merge_sessions(session_ids: Array[String]) -> Dictionary:
    var res: Dictionary = {"ok": false, "session_id": "", "name": "", "message": ""}
    if session_ids.size() < 2:
        res["message"] = "Выберите минимум 2 лога для совмещения."
        return res

    var indices: Array[int] = []
    for i in range(_sessions.size()):
        if session_ids.has(str(_sessions[i].get("id", ""))):
            indices.append(i)
    if indices.size() < 2:
        res["message"] = "Не удалось найти выбранные логи."
        return res
    indices.sort()

    var stamp: String = str(Time.get_unix_time_from_system()).replace(".", "_") + "_m"
    var merged_dir: String = "%s/session_%s" % [BACKUP_ROOT, stamp]
    DirAccess.make_dir_recursive_absolute(merged_dir)

    var merged_created: Array = []
    var merged_dirs: Array = []
    var merged_backed: Dictionary = {}
    var merged_deleted: Dictionary = {}
    var merged_ps: Dictionary = {}
    var merged_live_nodes: Array = []
    var merged_open_scene_path: String = ""
    var merged_open_scene_backup: String = ""
    var merged_open_scene_mod: bool = false

    var names: PackedStringArray = []
    var old_dirs: Array[String] = []
    var old_ids: Array[String] = []

    for idx in indices:
        var s: Dictionary = _sessions[idx]
        var sid: String = str(s.get("id", ""))
        old_ids.append(sid)
        names.append(str(s.get("name", "")))
        old_dirs.append(str(s.get("dir", "")))

        if _live_created_nodes.has(sid):
            merged_live_nodes.append_array(_live_created_nodes[sid])

        for d in s.get("created_dirs", []):
            var dp: String = str(d)
            if not merged_dirs.has(dp):
                merged_dirs.append(dp)

        for f in s.get("created_files", []):
            var fp: String = str(f)
            if merged_deleted.has(fp):
                merged_backed[fp] = merged_deleted[fp]
                merged_deleted.erase(fp)
            elif not merged_backed.has(fp) and not merged_created.has(fp):
                merged_created.append(fp)

        var bmap: Dictionary = s.get("backed_up_files", {})
        for orig_p in bmap.keys():
            var op: String = str(orig_p)
            if merged_created.has(op) or merged_backed.has(op):
                continue
            var src_b: String = str(bmap[orig_p])
            var dst_b: String = _copy_file_to_dir(src_b, merged_dir, op)
            if dst_b != "":
                merged_backed[op] = dst_b

        var dmap: Dictionary = s.get("deleted_files", {})
        for del_p in dmap.keys():
            var dp_str: String = str(del_p)
            if merged_created.has(dp_str):
                merged_created.erase(dp_str)
            elif merged_backed.has(dp_str):
                merged_deleted[dp_str] = merged_backed[dp_str]
                merged_backed.erase(dp_str)
            elif not merged_deleted.has(dp_str):
                var src_d: String = str(dmap[del_p])
                var dst_d: String = _copy_file_to_dir(src_d, merged_dir, dp_str)
                if dst_d != "":
                    merged_deleted[dp_str] = dst_d

        var ps_m: Dictionary = s.get("project_settings", {})
        for k in ps_m.keys():
            var ks: String = str(k)
            if not merged_ps.has(ks):
                merged_ps[ks] = (ps_m[k] as Dictionary).duplicate(true)

        if bool(s.get("open_scene_modified", false)) and not merged_open_scene_mod:
            var spath: String = str(s.get("open_scene_path", ""))
            var sback: String = str(s.get("open_scene_backup", ""))
            if spath != "" and sback != "" and FileAccess.file_exists(sback):
                var new_snap: String = merged_dir + "/_open_scene_snapshot.tscn"
                if _restore_file(sback, new_snap):
                    merged_open_scene_path = spath
                    merged_open_scene_backup = new_snap
                    merged_open_scene_mod = true

    var clean_code: String = _build_clean_merged_script(merged_created, merged_backed, merged_deleted, merged_ps, names)
    var insert_pos: int = indices[0]

    for j in range(indices.size() - 1, -1, -1):
        _sessions.remove_at(indices[j])
    for oid in old_ids:
        _live_created_nodes.erase(oid)
    for odir in old_dirs:
        _remove_dir_recursive(odir)

    var dt: String = Time.get_datetime_string_from_system(false, true)
    var merged_session: Dictionary = {
        "id": stamp,
        "number": insert_pos + 1,
        "name": str(insert_pos + 1),
        "is_renamed": false,
        "timestamp": dt,
        "code": clean_code,
        "dir": merged_dir,
        "created_files": merged_created,
        "created_dirs": merged_dirs,
        "backed_up_files": merged_backed,
        "deleted_files": merged_deleted,
        "project_settings": merged_ps,
        "open_scene_path": merged_open_scene_path,
        "open_scene_backup": merged_open_scene_backup,
        "open_scene_modified": merged_open_scene_mod
    }

    _sessions.insert(insert_pos, merged_session)
    if not merged_live_nodes.is_empty():
        _live_created_nodes[stamp] = merged_live_nodes

    _renumber_sessions()
    _save_history()

    res["ok"] = true
    res["session_id"] = stamp
    res["name"] = str(merged_session["name"])
    res["message"] = "Совмещено логов: %d -> единый чистый код в логе «%s»!" % [indices.size(), str(merged_session["name"])]
    return res


func _build_clean_merged_script(created: Array, backed: Dictionary, deleted: Dictionary, ps_map: Dictionary, names: PackedStringArray) -> String:
    var out: PackedStringArray = []
    out.append("# Чистый объединённый скрипт из логов: " + ", ".join(names))
    out.append("# Сгенерирован из итогового состояния файлов (без промежуточных багов и дублей)")
    out.append("func run(ai):")

    var has_any_op: bool = false

    for k in ps_map.keys():
        var key_str: String = str(k)
        if key_str == "application/run/main_scene":
            continue
        if ProjectSettings.has_setting(key_str):
            var cur_val: Variant = ProjectSettings.get_setting(key_str)
            out.append("\tai.set_project_setting(%s, %s)" % [var_to_str(key_str), var_to_str(cur_val)])
            has_any_op = true

    for del_p in deleted.keys():
        var dp: String = str(del_p)
        if not FileAccess.file_exists(dp):
            out.append("\tai.delete_file(%s)" % var_to_str(dp))
            has_any_op = true

    var all_paths: Array[String] = []
    for p in created:
        var ps: String = str(p)
        if not all_paths.has(ps):
            all_paths.append(ps)
    for p in backed.keys():
        var ps: String = str(p)
        if ps != "res://project.godot" and not all_paths.has(ps):
            all_paths.append(ps)

    var text_files: Array[String] = []
    var scene_files: Array[String] = []
    for p in all_paths:
        if not FileAccess.file_exists(p):
            continue
        if p.ends_with(".tscn") or p.ends_with(".tres"):
            scene_files.append(p)
        else:
            text_files.append(p)

    var idx: int = 1
    for fpath in text_files:
        var content: String = FileAccess.get_file_as_string(fpath)
        var vname := "src_%d" % idx
        idx += 1
        out.append("\n\t# Файл: " + fpath)
        out.append("\tvar %s = %s" % [vname, _to_gd_multiline_literal(content)])
        out.append("\tai.write_file(%s, %s)" % [var_to_str(fpath), vname])
        has_any_op = true

    for spath in scene_files:
        var content: String = FileAccess.get_file_as_string(spath)
        var vname := "scn_%d" % idx
        idx += 1
        out.append("\n\t# Сцена / Ресурс: " + spath)
        out.append("\tvar %s = %s" % [vname, _to_gd_multiline_literal(content)])
        out.append("\tai.write_file(%s, %s)" % [var_to_str(spath), vname])
        has_any_op = true

    if ps_map.has("application/run/main_scene"):
        var ms: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
        if ms != "":
            out.append("\tai.set_main_scene(%s)" % var_to_str(ms))
            has_any_op = true

    if not has_any_op:
        out.append("\tai.log(\"Нет активных изменений.\")")
    else:
        out.append("\tai.log(\"Объединённый проект успешно применён!\")")

    return "\n".join(out)


func _to_gd_multiline_literal(txt: String) -> String:
    if not ("\"\"\"" in txt) and not txt.ends_with("\""):
        return "\"\"\"" + txt + "\"\"\""
    return var_to_str(txt)


func _copy_file_to_dir(src_backup: String, dest_dir: String, orig_res_path: String) -> String:
    if src_backup.is_empty() or not FileAccess.file_exists(src_backup):
        return ""
    var safe_name: String = orig_res_path.replace("res://", "").replace("/", "__").replace(":", "_")
    var dest: String = dest_dir + "/" + safe_name
    var data: PackedByteArray = FileAccess.get_file_as_bytes(src_backup)
    var f := FileAccess.open(dest, FileAccess.WRITE)
    if f == null:
        return ""
    f.store_buffer(data)
    f.close()
    return dest


func undo_last_session() -> Dictionary:
    if _sessions.is_empty():
        return {
            "ok": false,
            "restored": [],
            "removed": [],
            "removed_dirs": [],
            "removed_nodes": 0,
            "restored_settings": 0,
            "reloaded_scene": "",
            "message": "Нет сохранённых логов для отмены."
        }
    var last_id: String = str(_sessions[_sessions.size() - 1].get("id", ""))
    return undo_session_by_id(last_id)


func undo_session_by_id(session_id: String) -> Dictionary:
    var result: Dictionary = {
        "ok": false,
        "session_name": "",
        "restored": [],
        "removed": [],
        "removed_dirs": [],
        "removed_nodes": 0,
        "restored_settings": 0,
        "reloaded_scene": "",
        "message": ""
    }

    var idx: int = -1
    for i in range(_sessions.size()):
        if str(_sessions[i].get("id", "")) == session_id:
            idx = i
            break

    if idx == -1:
        result["message"] = "Лог не найден."
        return result

    var session: Dictionary = _sessions[idx]
    _sessions.remove_at(idx)
    _renumber_sessions()
    result["session_name"] = str(session.get("name", ""))

    var ed := _get_editor()
    var created_files_list: Array = session.get("created_files", [])

    if Engine.is_editor_hint() and ed != null:
        var cur_root: Node = ed.get_edited_scene_root()
        if cur_root != null and cur_root.scene_file_path != "":
            var cur_path: String = _normalize_path(cur_root.scene_file_path)
            if created_files_list.has(cur_path) and ed.has_method("close_scene"):
                ed.call("close_scene")

    var removed_arr: Array = result["removed"]
    for item in created_files_list:
        var created_path: String = str(item)
        if FileAccess.file_exists(created_path):
            if DirAccess.remove_absolute(created_path) == OK:
                removed_arr.append(created_path)
        for sidecar_ext in [".uid", ".import"]:
            var sidecar: String = created_path + sidecar_ext
            if FileAccess.file_exists(sidecar):
                DirAccess.remove_absolute(sidecar)

    var dirs_to_remove: Array[String] = []
    for d_item in session.get("created_dirs", []):
        dirs_to_remove.append(str(d_item))
    dirs_to_remove.sort_custom(func(a: String, b: String) -> bool: return a.length() > b.length())

    var removed_dirs_arr: Array = result["removed_dirs"]
    for dpath in dirs_to_remove:
        if DirAccess.dir_exists_absolute(dpath) and _is_dir_empty(dpath):
            if DirAccess.remove_absolute(dpath) == OK:
                removed_dirs_arr.append(dpath)

    if _live_created_nodes.has(session_id):
        var live_arr: Array = _live_created_nodes[session_id]
        for wr_item in live_arr:
            if wr_item is WeakRef:
                var obj: Object = (wr_item as WeakRef).get_ref()
                if obj != null and is_instance_valid(obj) and obj is Node:
                    var n: Node = obj as Node
                    if n.get_parent() != null:
                        n.get_parent().remove_child(n)
                    n.queue_free()
                    result["removed_nodes"] = int(result["removed_nodes"]) + 1
        _live_created_nodes.erase(session_id)

    var restored_arr: Array = result["restored"]
    var ps_map: Dictionary = session.get("project_settings", {})
    var has_ps_undo: bool = not ps_map.is_empty()
    var backed_map: Dictionary = session.get("backed_up_files", {})
    for orig_path in backed_map.keys():
        if str(orig_path) == "res://project.godot" and has_ps_undo:
            continue
        var bpath: String = str(backed_map[orig_path])
        if _restore_file(bpath, str(orig_path)):
            restored_arr.append(str(orig_path))

    var deleted_map: Dictionary = session.get("deleted_files", {})
    for del_path in deleted_map.keys():
        var bpath: String = str(deleted_map[del_path])
        if _restore_file(bpath, str(del_path)):
            restored_arr.append(str(del_path))

    if has_ps_undo:
        var restored_ps_count: int = 0
        for key in ps_map.keys():
            var k: String = str(key)
            var info: Dictionary = ps_map[key]
            var existed: bool = bool(info.get("existed", false))
            if existed:
                var val: Variant = null
                if info.has("value_b64"):
                    var b64: String = str(info["value_b64"])
                    if not b64.is_empty():
                        var raw: PackedByteArray = Marshalls.base64_to_raw(b64)
                        val = bytes_to_var_with_objects(raw)
                elif info.has("value"):
                    val = info["value"]
                ProjectSettings.set_setting(k, val)
            else:
                ProjectSettings.set_setting(k, null)
            restored_ps_count += 1
        ProjectSettings.save()
        result["restored_settings"] = restored_ps_count
        restored_arr.append("res://project.godot (%d настроек)" % restored_ps_count)

    var open_scene_mod: bool = bool(session.get("open_scene_modified", false))
    var open_scene_path: String = str(session.get("open_scene_path", ""))
    var open_scene_backup: String = str(session.get("open_scene_backup", ""))
    if open_scene_mod and open_scene_path != "" and open_scene_backup != "" and FileAccess.file_exists(open_scene_backup):
        if _restore_file(open_scene_backup, open_scene_path):
            result["reloaded_scene"] = open_scene_path

    _remove_dir_recursive(str(session.get("dir", "")))
    _save_history()

    if Engine.is_editor_hint() and ed != null:
        ed.get_resource_filesystem().scan()
        var rel_scene: String = str(result["reloaded_scene"])
        if rel_scene != "" and FileAccess.file_exists(rel_scene):
            ed.reload_scene_from_path(rel_scene)
            ed.open_scene_from_path(rel_scene)

    result["ok"] = true
    result["message"] = "Лог «%s» удалён: удалено файлов %d, папок %d, узлов %d, восстановлено %d." % [
        str(result["session_name"]),
        removed_arr.size(),
        removed_dirs_arr.size(),
        int(result["removed_nodes"]),
        restored_arr.size()
    ]
    return result


func _renumber_sessions() -> void:
    for i in range(_sessions.size()):
        var s: Dictionary = _sessions[i]
        var old_num: int = int(s.get("number", i + 1))
        var new_num: int = i + 1
        var cur_name: String = str(s.get("name", ""))
        var is_custom: bool = bool(s.get("is_renamed", false))
        if not is_custom or cur_name == str(old_num) or cur_name.is_empty():
            s["name"] = str(new_num)
            s["is_renamed"] = false
        s["number"] = new_num
    _next_number = _sessions.size() + 1


func _load_history() -> void:
    _sessions.clear()
    _next_number = 1
    if not FileAccess.file_exists(HISTORY_FILE):
        return
    var txt: String = FileAccess.get_file_as_string(HISTORY_FILE)
    var parsed: Variant = JSON.parse_string(txt)
    if not (parsed is Dictionary):
        return
    var data: Dictionary = parsed
    var raw_list: Variant = data.get("sessions", [])
    if raw_list is Array:
        for item in raw_list:
            if item is Dictionary:
                var s: Dictionary = item
                if not s.has("is_renamed"):
                    s["is_renamed"] = (str(s.get("name", "")) != str(s.get("number", "")))
                _sessions.append(s)
    _renumber_sessions()


func _save_history() -> void:
    _ensure_backup_root()
    var payload: Dictionary = {
        "next_number": _next_number,
        "sessions": _sessions
    }
    var f := FileAccess.open(HISTORY_FILE, FileAccess.WRITE)
    if f:
        f.store_string(JSON.stringify(payload, "\t"))
        f.close()


func _snapshot_project_fs() -> Dictionary:
    var files: Dictionary = {}
    var dirs: Dictionary = {}
    _walk_fs("res://", files, dirs)
    return {"files": files, "dirs": dirs}


func _walk_fs(path: String, files: Dictionary, dirs: Dictionary) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        return
    dir.list_dir_begin()
    var name: String = dir.get_next()
    while name != "":
        if name != "." and name != ".." and name != ".godot" and name != ".git" and name != ".ai_executor_backups":
            var full: String = path.path_join(name)
            if dir.current_is_dir():
                dirs[full] = true
                _walk_fs(full, files, dirs)
            else:
                files[full] = true
        name = dir.get_next()
    dir.list_dir_end()


func _is_dir_empty(path: String) -> bool:
    var dir := DirAccess.open(path)
    if dir == null:
        return false
    dir.list_dir_begin()
    var name: String = dir.get_next()
    var empty: bool = true
    while name != "":
        if name != "." and name != "..":
            empty = false
            break
        name = dir.get_next()
    dir.list_dir_end()
    return empty


func _copy_to_backup(res_path: String) -> String:
    var safe_name: String = res_path.replace("res://", "").replace("/", "__").replace(":", "_")
    var dest: String = str(_current_session["dir"]) + "/" + safe_name
    var src_bytes: PackedByteArray = FileAccess.get_file_as_bytes(res_path)
    var f := FileAccess.open(dest, FileAccess.WRITE)
    if f == null:
        return ""
    f.store_buffer(src_bytes)
    f.close()
    return dest


func _restore_file(backup_path: String, target_res_path: String) -> bool:
    if not FileAccess.file_exists(backup_path):
        return false
    var dir_path: String = target_res_path.get_base_dir()
    if not DirAccess.dir_exists_absolute(dir_path):
        DirAccess.make_dir_recursive_absolute(dir_path)
    var data: PackedByteArray = FileAccess.get_file_as_bytes(backup_path)
    var f := FileAccess.open(target_res_path, FileAccess.WRITE)
    if f == null:
        return false
    f.store_buffer(data)
    f.close()
    return true


func _remove_dir_recursive(path: String) -> void:
    if path.is_empty() or not DirAccess.dir_exists_absolute(path):
        return
    var dir := DirAccess.open(path)
    if dir == null:
        return
    dir.list_dir_begin()
    var file_name: String = dir.get_next()
    while file_name != "":
        if file_name != "." and file_name != "..":
            var full: String = path + "/" + file_name
            if dir.current_is_dir():
                _remove_dir_recursive(full)
            else:
                DirAccess.remove_absolute(full)
        file_name = dir.get_next()
    dir.list_dir_end()
    DirAccess.remove_absolute(path)


func _normalize_path(path: String) -> String:
    var p: String = path.strip_edges()
    if not p.begins_with("res://") and not p.begins_with("user://"):
        p = "res://" + p.trim_prefix("/")
    return p
