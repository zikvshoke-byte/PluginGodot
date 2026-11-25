@tool
class_name AIContext
extends RefCounted

## Универсальный программный интерфейс (API v2.0), передаваемый в `run(ai)`.
## Поддерживает точечные патчи с проверкой синтаксиса, компактное построение сцен
## и полный контроль над проектом Godot 4.x (Android & Desktop).

var _plugin: EditorPlugin
var _backup: AIBackupManager
var _safe_mode: bool = true

var logs: Array[Dictionary] = []
var modified_files: Array[String] = []
var pending_deletions: Array[String] = []
var scene_modified: bool = false


func _init(plugin: EditorPlugin, backup_manager: AIBackupManager, safe_mode: bool = true) -> void:
    _plugin = plugin
    _backup = backup_manager
    _safe_mode = safe_mode


# ==============================================================================
# 1. ЛОГИРОВАНИЕ, ИНСПЕКЦИЯ И ЭКСПОРТ КОНТЕКСТА ДЛЯ ИИ
# ==============================================================================

func log(msg: Variant) -> void:
    logs.append({"level": "INFO", "text": str(msg)})


func warn(msg: Variant) -> void:
    logs.append({"level": "WARN", "text": str(msg)})


func error(msg: Variant) -> void:
    logs.append({"level": "ERROR", "text": str(msg)})


func get_editor() -> EditorInterface:
    return _plugin.get_editor_interface() if _plugin else null


func get_undo_redo() -> EditorUndoRedoManager:
    return _plugin.get_undo_redo() if _plugin else null


func get_scene_tree_text(root: Node = null, max_depth: int = 10) -> String:
    var target: Node = root if root != null else get_edited_scene()
    if target == null:
        return "<Нет открытой сцены>"
    var lines: PackedStringArray = []
    _dump_tree(target, 0, max_depth, lines)
    return "\n".join(lines)


func _dump_tree(node: Node, depth: int, max_depth: int, lines: PackedStringArray) -> void:
    if depth > max_depth:
        return
    var indent: String = "  ".repeat(depth)
    var scr_info: String = ""
    var scr: Variant = node.get_script()
    if scr is Script and (scr as Script).resource_path != "":
        scr_info = " [%s]" % (scr as Script).resource_path.get_file()
    lines.append("%s- %s (%s)%s" % [indent, node.name, node.get_class(), scr_info])
    for child in node.get_children():
        _dump_tree(child, depth + 1, max_depth, lines)


func get_project_summary(max_files: int = 80) -> String:
    var lines: PackedStringArray = []
    lines.append("=== КОНТЕКСТ ПРОЕКТА GODOT ===")
    lines.append("Главная сцена: " + str(get_project_setting("application/run/main_scene", "<не задана>")))

    var all_files: PackedStringArray = list_files("res://", true)
    var filtered: PackedStringArray = []
    for f in all_files:
        if f.begins_with("res://addons/ai_code_executor/"):
            continue
        if f.ends_with(".uid") or f.ends_with(".import"):
            continue
        filtered.append(f)

    lines.append("\nФайлы проекта (%d):" % filtered.size())
    var lim: int = min(filtered.size(), max_files)
    for i in range(lim):
        lines.append("  - " + filtered[i])
    if filtered.size() > max_files:
        lines.append("  ... и ещё %d файлов" % (filtered.size() - max_files))

    var edited: Node = get_edited_scene()
    if edited != null:
        lines.append("\nОткрытая сцена (%s):" % edited.scene_file_path)
        lines.append(get_scene_tree_text(edited, 6))

    return "\n".join(lines)


# ==============================================================================
# 2. ТОЧЕЧНЫЕ ПАТЧИ И АВТОПРОВЕРКА GDSCRIPT (ЭКОНОМИЯ ТОКЕНОВ И БЕЗ БАГОВ)
# ==============================================================================

func validate_gdscript(code: String) -> Dictionary:
    var check_code: String = ""
    # Убираем class_name только во временном буфере проверки, чтобы избежать ложного конфликта имён
    for raw_line in code.split("\n"):
        if raw_line.strip_edges().begins_with("class_name "):
            check_code += "# " + raw_line + "\n"
        else:
            check_code += raw_line + "\n"

    var gd := GDScript.new()
    gd.source_code = check_code
    var err: int = gd.reload(true)
    if err != OK:
        return {
            "ok": false,
            "error": "Синтаксическая ошибка GDScript (код %d). Подробности см. во вкладке 'Вывод / Output'." % err
        }
    return {"ok": true, "error": ""}


func patch_file(path: String, replacements: Dictionary, validate_gd: bool = true) -> bool:
    var norm: String = _norm(path)
    if not FileAccess.file_exists(norm):
        error("patch_file: файл не найден: " + norm)
        return false

    var content: String = FileAccess.get_file_as_string(norm)
    var new_content: String = content
    var applied: int = 0

    for old_key in replacements.keys():
        var old_str: String = str(old_key)
        var new_str: String = str(replacements[old_key])
        if old_str.is_empty():
            error("patch_file: пустой ключ поиска в " + norm)
            return false

        var occurrences: int = new_content.count(old_str)
        if occurrences == 0:
            error("patch_file: фрагмент не найден в %s -> '%s'" % [norm, old_str.left(60).replace("\n", "\\n")])
            return false
        if occurrences > 1:
            error("patch_file: фрагмент встречается %d раз в %s (укажите более уникальный контекст) -> '%s'" % [occurrences, norm, old_str.left(60).replace("\n", "\\n")])
            return false

        new_content = new_content.replace(old_str, new_str)
        applied += 1

    if validate_gd and norm.ends_with(".gd"):
        var chk: Dictionary = validate_gdscript(new_content)
        if not bool(chk["ok"]):
            error("patch_file отменён (%s): %s" % [norm, str(chk["error"])])
            return false

    if not write_file(norm, new_content):
        return false

    self.log("Патч применён к %s (замен: %d)" % [norm, applied])
    return true


func replace_func(path: String, func_name: String, new_func_code: String, validate_gd: bool = true) -> bool:
    var norm: String = _norm(path)
    if not FileAccess.file_exists(norm):
        error("replace_func: файл не найден: " + norm)
        return false

    var content: String = FileAccess.get_file_as_string(norm)
    var lines: PackedStringArray = content.split("\n")
    var start_idx: int = -1

    for i in range(lines.size()):
        var l: String = lines[i]
        if l.begins_with("func " + func_name + "(") or l.begins_with("static func " + func_name + "("):
            start_idx = i
            break

    if start_idx == -1:
        error("replace_func: функция '%s' не найдена в %s" % [func_name, norm])
        return false

    var end_idx: int = lines.size()
    for j in range(start_idx + 1, lines.size()):
        var l: String = lines[j]
        if l.strip_edges().is_empty():
            continue
        if not l.begins_with("\t") and not l.begins_with(" ") and not l.begins_with("#"):
            end_idx = j
            break

    # Сохраняем пустые строки и комментарии, относящиеся к следующей функции
    while end_idx > start_idx + 1:
        var prev: String = lines[end_idx - 1].strip_edges()
        if prev.is_empty() or prev.begins_with("#"):
            end_idx -= 1
        else:
            break

    var out_lines: PackedStringArray = []
    for i in range(start_idx):
        out_lines.append(lines[i])
    for nl in new_func_code.strip_edges(false, true).split("\n"):
        out_lines.append(nl)
    for i in range(end_idx, lines.size()):
        out_lines.append(lines[i])

    var new_content: String = "\n".join(out_lines)
    if validate_gd and norm.ends_with(".gd"):
        var chk: Dictionary = validate_gdscript(new_content)
        if not bool(chk["ok"]):
            error("replace_func отменён (%s::%s): %s" % [norm, func_name, str(chk["error"])])
            return false

    if not write_file(norm, new_content):
        return false

    self.log("Функция %s() обновлена в %s" % [func_name, norm])
    return true


func insert_in_file(path: String, anchor: String, text_to_insert: String, after: bool = true, validate_gd: bool = true) -> bool:
    var norm: String = _norm(path)
    if not FileAccess.file_exists(norm):
        error("insert_in_file: файл не найден: " + norm)
        return false

    var content: String = FileAccess.get_file_as_string(norm)
    var cnt: int = content.count(anchor)
    if cnt != 1:
        error("insert_in_file: якорь найден %d раз (нужно ровно 1) в %s" % [cnt, norm])
        return false

    var repl: String = (anchor + "\n" + text_to_insert) if after else (text_to_insert + "\n" + anchor)
    var new_content: String = content.replace(anchor, repl)

    if validate_gd and norm.ends_with(".gd"):
        var chk: Dictionary = validate_gdscript(new_content)
        if not bool(chk["ok"]):
            error("insert_in_file отменён (%s): %s" % [norm, str(chk["error"])])
            return false

    return write_file(norm, new_content)


func append_to_file(path: String, text_to_append: String, validate_gd: bool = true) -> bool:
    var norm: String = _norm(path)
    if not FileAccess.file_exists(norm):
        error("append_to_file: файл не найден: " + norm)
        return false

    var content: String = FileAccess.get_file_as_string(norm)
    var sep: String = "\n\n" if not content.ends_with("\n") else "\n"
    var new_content: String = content + sep + text_to_append

    if validate_gd and norm.ends_with(".gd"):
        var chk: Dictionary = validate_gdscript(new_content)
        if not bool(chk["ok"]):
            error("append_to_file отменён (%s): %s" % [norm, str(chk["error"])])
            return false

    return write_file(norm, new_content)


func read_lines(path: String, from_line: int = 1, to_line: int = -1) -> String:
    var content: String = read_file(path)
    if content.is_empty():
        return ""
    var lines: PackedStringArray = content.split("\n")
    var start_i: int = max(0, from_line - 1)
    var end_i: int = lines.size() if to_line < 0 else min(lines.size(), to_line)
    var out: PackedStringArray = []
    for i in range(start_i, end_i):
        out.append("%4d | %s" % [i + 1, lines[i]])
    return "\n".join(out)


# ==============================================================================
# 3. СЦЕНЫ, КОМПАКТНОЕ РЕДАКТИРОВАНИЕ И ДЕКЛАРАТИВНЫЙ BUILDER
# ==============================================================================

func get_edited_scene() -> Node:
    var ed := get_editor()
    return ed.get_edited_scene_root() if ed else null


func create_scene(root_type: String = "Node3D", root_name: String = "Main") -> Node:
    if not ClassDB.class_exists(root_type) or not ClassDB.can_instantiate(root_type):
        error("Невозможно создать корневой узел типа: " + root_type)
        return null
    var root: Node = ClassDB.instantiate(root_type)
    root.name = root_name
    scene_modified = true
    return root


func load_scene(path: String) -> Node:
    var norm := _norm(path)
    if not ResourceLoader.exists(norm):
        error("Сцена не найдена: " + norm)
        return null
    var packed: PackedScene = ResourceLoader.load(norm, "", ResourceLoader.CACHE_MODE_IGNORE)
    if packed == null:
        error("Не удалось загрузить PackedScene: " + norm)
        return null
    return packed.instantiate()


func edit_scene(path: String, callback: Callable, open_in_editor: bool = true) -> bool:
    var norm: String = _norm(path)
    var edited: Node = get_edited_scene()
    if edited != null and _norm(edited.scene_file_path) == norm:
        callback.call(edited)
        return save_current_scene()

    var root: Node = load_scene(norm)
    if root == null:
        return false
    callback.call(root)
    var ok: bool = save_scene(root, norm, open_in_editor)
    root.queue_free()
    return ok


func build_tree(parent: Node, specs: Array) -> Array[Node]:
    var created: Array[Node] = []
    if parent == null:
        return created
    for item in specs:
        if not (item is Dictionary):
            continue
        var d: Dictionary = item
        var node: Node = null
        if d.has("scene"):
            node = instance_scene(parent, str(d["scene"]), str(d.get("name", "")), d.get("props", {}))
        elif d.has("box"):
            node = create_box(
                parent,
                str(d.get("name", "Box")),
                d["box"],
                d.get("pos", Vector3.ZERO),
                d.get("mat", null),
                bool(d.get("col", true))
            )
        else:
            var tname: String = str(d.get("type", "Node3D"))
            node = add_node(parent, tname, str(d.get("name", "")), d.get("props", {}))

        if node == null:
            continue

        if node is Node3D:
            set_transform_3d(node as Node3D, d.get("pos", null), d.get("rot", null), d.get("scale", null))
        elif node is Node2D:
            set_transform_2d(node as Node2D, d.get("pos", null), d.get("rot", null), d.get("scale", null))

        if d.has("mat") and not d.has("box"):
            set_material(node, d["mat"])
        if d.has("script"):
            attach_script(node, str(d["script"]))
        if d.has("group"):
            add_to_group(node, str(d["group"]))
        if d.has("groups") and d["groups"] is Array:
            for g in d["groups"]:
                add_to_group(node, str(g))
        if d.has("children") and d["children"] is Array:
            build_tree(node, d["children"])

        created.append(node)
    return created


func save_scene(root_node: Node, path: String, open_in_editor: bool = true) -> bool:
    if root_node == null:
        error("save_scene: root_node == null")
        return false
    var norm := _norm(path)
    if not norm.ends_with(".tscn") and not norm.ends_with(".scn"):
        norm += ".tscn"

    make_dir(norm.get_base_dir())
    _ensure_owners(root_node, root_node)

    var packed := PackedScene.new()
    var pack_err := packed.pack(root_node)
    if pack_err != OK:
        error("Ошибка упаковки сцены (%s): код %d" % [norm, pack_err])
        return false

    _backup.record_before_write(norm)
    var save_err := ResourceSaver.save(packed, norm)
    if save_err != OK:
        error("Ошибка сохранения сцены (%s): код %d" % [norm, save_err])
        return false

    _track_modified(norm)
    scene_modified = true
    scan_filesystem()

    if open_in_editor:
        open_scene(norm)

    self.log("Сцена сохранена: " + norm)
    return true


func save_current_scene() -> bool:
    var root := get_edited_scene()
    if root == null:
        error("Нет открытой сцены для сохранения.")
        return false
    _backup.mark_open_scene_modified()
    if root.scene_file_path != "":
        _backup.record_before_write(root.scene_file_path)
        _track_modified(root.scene_file_path)
    var ed := get_editor()
    if ed == null:
        return false
    var err := ed.save_scene()
    if err != OK:
        error("Ошибка сохранения текущей сцены: код " + str(err))
        return false
    self.log("Текущая сцена сохранена.")
    return true


func open_scene(path: String) -> void:
    var norm := _norm(path)
    var ed := get_editor()
    if ed and FileAccess.file_exists(norm):
        ed.open_scene_from_path(norm)
    else:
        error("open_scene: файл не существует: " + norm)


func reload_current_scene() -> void:
    var root := get_edited_scene()
    var ed := get_editor()
    if ed and root and root.scene_file_path != "":
        ed.reload_scene_from_path(root.scene_file_path)


func scan_filesystem() -> void:
    var ed := get_editor()
    if ed:
        ed.get_resource_filesystem().scan()


# ==============================================================================
# 4. УНИВЕРСАЛЬНАЯ РАБОТА С УЗЛАМИ
# ==============================================================================

func add_node(parent: Node, type_name: String, node_name: String = "", props: Dictionary = {}) -> Node:
    if parent == null:
        error("add_node: parent == null для типа " + type_name)
        return null
    if not ClassDB.class_exists(type_name) or not ClassDB.can_instantiate(type_name):
        error("add_node: неизвестный или неинстанцируемый тип: " + type_name)
        return null

    var node: Node = ClassDB.instantiate(type_name)
    if node_name != "":
        node.name = node_name
    parent.add_child(node, true)
    var root := _get_scene_root(parent)
    node.owner = root

    _check_open_scene_touch(root, node)

    if not props.is_empty():
        set_props(node, props)

    scene_modified = true
    return node


func instance_scene(parent: Node, scene_path: String, node_name: String = "", props: Dictionary = {}) -> Node:
    if parent == null:
        error("instance_scene: parent == null")
        return null
    var norm := _norm(scene_path)
    if not ResourceLoader.exists(norm):
        error("instance_scene: сцена не найдена: " + norm)
        return null

    var packed: PackedScene = load(norm)
    if packed == null:
        error("instance_scene: ошибка загрузки " + norm)
        return null

    var inst: Node = packed.instantiate()
    if node_name != "":
        inst.name = node_name
    parent.add_child(inst, true)
    var root := _get_scene_root(parent)
    inst.owner = root

    _check_open_scene_touch(root, inst)

    if not props.is_empty():
        set_props(inst, props)

    scene_modified = true
    return inst


func find_node(root: Node, name_or_path: String) -> Node:
    if root == null:
        return null
    if root.has_node(name_or_path):
        return root.get_node(name_or_path)
    return root.find_child(name_or_path, true, false)


func get_nodes_by_type(root: Node, type_name: String) -> Array[Node]:
    var result: Array[Node] = []
    if root == null:
        return result
    _collect_by_type(root, type_name, result)
    return result


func _collect_by_type(node: Node, type_name: String, out: Array[Node]) -> void:
    if node.is_class(type_name):
        out.append(node)
    for child in node.get_children():
        _collect_by_type(child, type_name, out)


func rename_node(node: Node, new_name: String) -> Node:
    if node == null or new_name.strip_edges().is_empty():
        return node
    node.name = new_name.strip_edges()
    _check_open_scene_touch(_get_scene_root(node))
    scene_modified = true
    return node


func set_props(obj: Object, props: Dictionary) -> Object:
    if obj == null:
        return null
    for key in props.keys():
        var k := str(key)
        var val = props[key]
        if ":" in k:
            obj.set_indexed(NodePath(k), val)
        else:
            obj.set(k, val)
    if obj is Node:
        _check_open_scene_touch(_get_scene_root(obj as Node))
    scene_modified = true
    return obj


func set_transform_3d(node: Node3D, pos: Variant = null, rot_deg: Variant = null, scl: Variant = null) -> Node3D:
    if node == null:
        return null
    if pos is Vector3:
        node.position = pos
    if rot_deg is Vector3:
        node.rotation_degrees = rot_deg
    if scl is Vector3:
        node.scale = scl
    _check_open_scene_touch(_get_scene_root(node))
    scene_modified = true
    return node


func set_transform_2d(node: Node2D, pos: Variant = null, rot_deg: Variant = null, scl: Variant = null) -> Node2D:
    if node == null:
        return null
    if pos is Vector2:
        node.position = pos
    if rot_deg is float or rot_deg is int:
        node.rotation_degrees = float(rot_deg)
    if scl is Vector2:
        node.scale = scl
    _check_open_scene_touch(_get_scene_root(node))
    scene_modified = true
    return node


func reparent_node(node: Node, new_parent: Node) -> void:
    if node == null or new_parent == null:
        return
    var old_parent := node.get_parent()
    if old_parent:
        old_parent.remove_child(node)
    new_parent.add_child(node, true)
    var new_root := _get_scene_root(new_parent)
    node.owner = new_root
    _ensure_owners(node, new_root)
    _check_open_scene_touch(new_root)
    scene_modified = true


func move_node(node: Node, to_index: int) -> void:
    if node == null or node.get_parent() == null:
        return
    node.get_parent().move_child(node, to_index)
    _check_open_scene_touch(_get_scene_root(node))
    scene_modified = true


func remove_node(node: Node) -> void:
    if node == null:
        return
    _check_open_scene_touch(_get_scene_root(node))
    if node.get_parent():
        node.get_parent().remove_child(node)
    node.queue_free()
    scene_modified = true


func connect_signal(source: Node, signal_name: String, target: Node, method_name: String) -> bool:
    if source == null or target == null:
        error("connect_signal: source или target == null")
        return false
    if not source.has_signal(signal_name):
        error("connect_signal: узел %s не имеет сигнала '%s'" % [source.name, signal_name])
        return false
    var cb := Callable(target, method_name)
    if not source.is_connected(signal_name, cb):
        var err := source.connect(signal_name, cb, Object.CONNECT_PERSIST)
        if err != OK:
            error("connect_signal: ошибка подключения (%d)" % err)
            return false
    _check_open_scene_touch(_get_scene_root(source))
    scene_modified = true
    return true


func add_to_group(node: Node, group_name: String) -> void:
    if node == null:
        return
    node.add_to_group(group_name, true)
    _check_open_scene_touch(_get_scene_root(node))
    scene_modified = true


func set_collision_layers(node: Node, layers: Array = [], masks: Array = []) -> Node:
    if node == null:
        return null
    if not layers.is_empty():
        var layer_bits := 0
        for l in layers:
            var idx := int(l)
            if idx >= 1 and idx <= 32:
                layer_bits |= (1 << (idx - 1))
        node.set("collision_layer", layer_bits)
    if not masks.is_empty():
        var mask_bits := 0
        for m in masks:
            var idx := int(m)
            if idx >= 1 and idx <= 32:
                mask_bits |= (1 << (idx - 1))
        node.set("collision_mask", mask_bits)
    _check_open_scene_touch(_get_scene_root(node))
    scene_modified = true
    return node


# ==============================================================================
# 5. 3D ХЕЛПЕРЫ (ГЕОМЕТРИЯ, CSG, СВЕТ, КАМЕРЫ, ОКРУЖЕНИЕ, ФИЗИКА, ЧАСТИЦЫ)
# ==============================================================================

func create_mesh(
    parent: Node,
    node_name: String,
    mesh_type: Variant = "box",
    mesh_props: Dictionary = {},
    pos: Vector3 = Vector3.ZERO,
    mat_props: Variant = null
) -> MeshInstance3D:
    var mi: MeshInstance3D = add_node(parent, "MeshInstance3D", node_name)
    if mi == null:
        return null
    mi.position = pos

    var mesh: Mesh = null
    if mesh_type is Mesh:
        mesh = mesh_type
    else:
        var t := str(mesh_type).to_lower()
        match t:
            "box", "boxmesh": mesh = BoxMesh.new()
            "sphere", "spheremesh": mesh = SphereMesh.new()
            "cylinder", "cylindermesh": mesh = CylinderMesh.new()
            "capsule", "capsulemesh": mesh = CapsuleMesh.new()
            "plane", "planemesh": mesh = PlaneMesh.new()
            "torus", "torusmesh": mesh = TorusMesh.new()
            "prism", "prismmesh": mesh = PrismMesh.new()
            "quad", "quadmesh": mesh = QuadMesh.new()
            _:
                if ClassDB.class_exists(str(mesh_type)):
                    mesh = ClassDB.instantiate(str(mesh_type))
                else:
                    mesh = BoxMesh.new()
                    warn("create_mesh: неизвестный тип '%s', использован BoxMesh" % str(mesh_type))

    if mesh and not mesh_props.is_empty():
        set_props(mesh, mesh_props)
    mi.mesh = mesh

    if mat_props != null:
        set_material(mi, mat_props)

    return mi


func create_box(
    parent: Node,
    node_name: String,
    size: Vector3 = Vector3.ONE,
    pos: Vector3 = Vector3.ZERO,
    mat_props: Variant = null,
    with_collision: bool = false
) -> Node3D:
    if with_collision:
        var body: StaticBody3D = add_node(parent, "StaticBody3D", node_name)
        body.position = pos
        create_mesh(body, "Mesh", "box", {"size": size}, Vector3.ZERO, mat_props)
        var col: CollisionShape3D = add_node(body, "CollisionShape3D", "Collision")
        var shape := BoxShape3D.new()
        shape.size = size
        col.shape = shape
        return body
    else:
        return create_mesh(parent, node_name, "box", {"size": size}, pos, mat_props)


func create_csg(
    parent: Node,
    node_name: String,
    csg_type: String = "CSGBox3D",
    props: Dictionary = {},
    pos: Vector3 = Vector3.ZERO,
    mat_props: Variant = null
) -> Node3D:
    var csg_class := csg_type
    if not csg_class.begins_with("CSG"):
        match csg_type.to_lower():
            "box": csg_class = "CSGBox3D"
            "sphere": csg_class = "CSGSphere3D"
            "cylinder": csg_class = "CSGCylinder3D"
            "torus": csg_class = "CSGTorus3D"
            "polygon": csg_class = "CSGPolygon3D"
            "combiner": csg_class = "CSGCombiner3D"
            "mesh": csg_class = "CSGMesh3D"

    var node: Node3D = add_node(parent, csg_class, node_name, props)
    if node == null:
        return null
    node.position = pos
    if mat_props != null:
        set_material(node, mat_props)
    return node


func create_light(
    parent: Node,
    light_type: String = "DirectionalLight3D",
    pos: Vector3 = Vector3.ZERO,
    rot_deg: Vector3 = Vector3(-45, 45, 0),
    props: Dictionary = {}
) -> Light3D:
    var cls := light_type
    match light_type.to_lower():
        "directional", "sun": cls = "DirectionalLight3D"
        "omni", "point": cls = "OmniLight3D"
        "spot": cls = "SpotLight3D"

    var light: Light3D = add_node(parent, cls, cls)
    if light == null:
        return null
    light.position = pos
    light.rotation_degrees = rot_deg
    light.shadow_enabled = true
    if not props.is_empty():
        set_props(light, props)
    return light


func create_camera_3d(
    parent: Node,
    node_name: String = "Camera3D",
    pos: Vector3 = Vector3(0, 2, 5),
    look_at_target: Variant = null,
    props: Dictionary = {}
) -> Camera3D:
    var cam: Camera3D = add_node(parent, "Camera3D", node_name, props)
    if cam == null:
        return null
    cam.position = pos
    if look_at_target is Vector3:
        cam.look_at_from_position(pos, look_at_target, Vector3.UP)
    return cam


func create_environment(parent: Node, env_props: Dictionary = {}, sky_props: Dictionary = {}) -> WorldEnvironment:
    var we: WorldEnvironment = add_node(parent, "WorldEnvironment", "WorldEnvironment")
    if we == null:
        return null
    var env := Environment.new()
    var sky := Sky.new()
    var sky_mat := ProceduralSkyMaterial.new()
    if not sky_props.is_empty():
        set_props(sky_mat, sky_props)
    sky.sky_material = sky_mat
    env.background_mode = Environment.BG_SKY
    env.sky = sky
    env.tonemap_mode = Environment.TONE_MAPPER_ACES
    if not env_props.is_empty():
        set_props(env, env_props)
    we.environment = env
    return we


func create_physics_3d(
    parent: Node,
    body_type: String,
    node_name: String,
    shape_type: String = "box",
    shape_props: Dictionary = {},
    pos: Vector3 = Vector3.ZERO,
    body_props: Dictionary = {}
) -> CollisionObject3D:
    var body: CollisionObject3D = add_node(parent, body_type, node_name, body_props)
    if body == null:
        return null
    body.position = pos
    var col: CollisionShape3D = add_node(body, "CollisionShape3D", "CollisionShape3D")
    col.shape = _make_shape_3d(shape_type, shape_props)
    return body


func create_collision_polygon_3d(
    parent: Node,
    node_name: String,
    polygon: PackedVector2Array,
    depth: float = 1.0,
    pos: Vector3 = Vector3.ZERO,
    props: Dictionary = {}
) -> CollisionPolygon3D:
    var col: CollisionPolygon3D = add_node(parent, "CollisionPolygon3D", node_name, props)
    if col == null:
        return null
    col.position = pos
    col.polygon = polygon
    col.depth = depth
    return col


func create_particles_3d(
    parent: Node,
    node_name: String = "GPUParticles3D",
    pos: Vector3 = Vector3.ZERO,
    amount: int = 32,
    process_mat_props: Dictionary = {},
    draw_mesh_type: String = "sphere",
    draw_mesh_props: Dictionary = {"radius": 0.1, "height": 0.2}
) -> GPUParticles3D:
    var p: GPUParticles3D = add_node(parent, "GPUParticles3D", node_name)
    if p == null:
        return null
    p.position = pos
    p.amount = amount
    var pmat := ParticleProcessMaterial.new()
    if not process_mat_props.is_empty():
        set_props(pmat, process_mat_props)
    p.process_material = pmat

    var mesh: Mesh
    match draw_mesh_type.to_lower():
        "box": mesh = BoxMesh.new()
        "quad": mesh = QuadMesh.new()
        "plane": mesh = PlaneMesh.new()
        _: mesh = SphereMesh.new()
    if not draw_mesh_props.is_empty():
        set_props(mesh, draw_mesh_props)
    p.draw_pass_1 = mesh
    return p


func _make_shape_3d(shape_type: String, props: Dictionary) -> Shape3D:
    var s: Shape3D
    match shape_type.to_lower():
        "box": s = BoxShape3D.new()
        "sphere": s = SphereShape3D.new()
        "capsule": s = CapsuleShape3D.new()
        "cylinder": s = CylinderShape3D.new()
        "world_boundary": s = WorldBoundaryShape3D.new()
        _:
            s = BoxShape3D.new()
    if not props.is_empty():
        set_props(s, props)
    return s


# ==============================================================================
# 6. 2D И UI ХЕЛПЕРЫ
# ==============================================================================

func create_sprite_2d(
    parent: Node,
    node_name: String,
    texture_path: String = "",
    pos: Vector2 = Vector2.ZERO,
    props: Dictionary = {}
) -> Sprite2D:
    var sp: Sprite2D = add_node(parent, "Sprite2D", node_name, props)
    if sp == null:
        return null
    sp.position = pos
    if texture_path != "":
        var tex := load_resource(texture_path)
        if tex is Texture2D:
            sp.texture = tex
    return sp


func create_camera_2d(
    parent: Node,
    node_name: String = "Camera2D",
    pos: Vector2 = Vector2.ZERO,
    props: Dictionary = {}
) -> Camera2D:
    var cam: Camera2D = add_node(parent, "Camera2D", node_name, props)
    if cam == null:
        return null
    cam.position = pos
    return cam


func create_physics_2d(
    parent: Node,
    body_type: String,
    node_name: String,
    shape_type: String = "rect",
    shape_props: Dictionary = {},
    pos: Vector2 = Vector2.ZERO,
    body_props: Dictionary = {}
) -> CollisionObject2D:
    var body: CollisionObject2D = add_node(parent, body_type, node_name, body_props)
    if body == null:
        return null
    body.position = pos
    var col: CollisionShape2D = add_node(body, "CollisionShape2D", "CollisionShape2D")
    col.shape = _make_shape_2d(shape_type, shape_props)
    return body


func create_collision_polygon_2d(
    parent: Node,
    node_name: String,
    polygon: PackedVector2Array,
    pos: Vector2 = Vector2.ZERO,
    props: Dictionary = {}
) -> CollisionPolygon2D:
    var col: CollisionPolygon2D = add_node(parent, "CollisionPolygon2D", node_name, props)
    if col == null:
        return null
    col.position = pos
    col.polygon = polygon
    return col


func create_particles_2d(
    parent: Node,
    node_name: String = "GPUParticles2D",
    pos: Vector2 = Vector2.ZERO,
    amount: int = 24,
    process_mat_props: Dictionary = {}
) -> GPUParticles2D:
    var p: GPUParticles2D = add_node(parent, "GPUParticles2D", node_name)
    if p == null:
        return null
    p.position = pos
    p.amount = amount
    var pmat := ParticleProcessMaterial.new()
    if not process_mat_props.is_empty():
        set_props(pmat, process_mat_props)
    p.process_material = pmat
    return p


func _make_shape_2d(shape_type: String, props: Dictionary) -> Shape2D:
    var s: Shape2D
    match shape_type.to_lower():
        "rect", "rectangle", "box": s = RectangleShape2D.new()
        "circle", "sphere": s = CircleShape2D.new()
        "capsule": s = CapsuleShape2D.new()
        "segment": s = SegmentShape2D.new()
        _:
            s = RectangleShape2D.new()
    if not props.is_empty():
        set_props(s, props)
    return s


func create_ui(
    parent: Node,
    control_type: String,
    node_name: String,
    props: Dictionary = {},
    anchors_preset: int = -1
) -> Control:
    var ctrl: Control = add_node(parent, control_type, node_name, props)
    if ctrl == null:
        return null
    if anchors_preset >= 0:
        ctrl.set_anchors_preset(anchors_preset)
    return ctrl


# ==============================================================================
# 7. МАТЕРИАЛЫ, ШЕЙДЕРЫ, АНИМАЦИИ И РЕСУРСЫ
# ==============================================================================

func create_material(props: Dictionary = {}) -> StandardMaterial3D:
    var mat := StandardMaterial3D.new()
    for key in props.keys():
        var k := str(key)
        var v = props[key]
        match k:
            "color":
                mat.albedo_color = v
            "texture":
                if v is String:
                    mat.albedo_texture = load_resource(v)
                elif v is Texture2D:
                    mat.albedo_texture = v
            "emission_color", "emission":
                mat.emission_enabled = true
                mat.emission = v
            "emission_energy":
                mat.emission_enabled = true
                mat.emission_energy_multiplier = float(v)
            "transparent":
                if v:
                    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
            _:
                mat.set(k, v)
    return mat


func set_material(target_node: Node, mat_or_props: Variant) -> Material:
    if target_node == null:
        return null
    var mat: Material = mat_or_props if mat_or_props is Material else create_material(mat_or_props)

    if target_node is MeshInstance3D:
        target_node.material_override = mat
    elif target_node.is_class("CSGPrimitive3D"):
        target_node.set("material", mat)
    else:
        for child in target_node.get_children():
            if child is MeshInstance3D:
                child.material_override = mat
                break
            elif child.is_class("CSGPrimitive3D"):
                child.set("material", mat)
                break

    _check_open_scene_touch(_get_scene_root(target_node))
    scene_modified = true
    return mat


func create_shader_material(shader_code: String, uniforms: Dictionary = {}, save_shader_path: String = "") -> ShaderMaterial:
    var shader := Shader.new()
    shader.code = shader_code
    if save_shader_path != "":
        save_resource(shader, save_shader_path)
    var mat := ShaderMaterial.new()
    mat.shader = shader
    for u_name in uniforms.keys():
        mat.set_shader_parameter(str(u_name), uniforms[u_name])
    return mat


func create_physics_material(friction: float = 1.0, bounce: float = 0.0, props: Dictionary = {}) -> PhysicsMaterial:
    var pm := PhysicsMaterial.new()
    pm.friction = friction
    pm.bounce = bounce
    if not props.is_empty():
        set_props(pm, props)
    return pm


func create_resource(type_name: String, props: Dictionary = {}) -> Resource:
    if not ClassDB.class_exists(type_name) or not ClassDB.can_instantiate(type_name):
        error("create_resource: неизвестный тип ресурса: " + type_name)
        return null
    var res: Resource = ClassDB.instantiate(type_name)
    if not props.is_empty():
        set_props(res, props)
    return res


func save_resource(res: Resource, path: String) -> bool:
    if res == null:
        error("save_resource: res == null")
        return false
    var norm := _norm(path)
    make_dir(norm.get_base_dir())
    _backup.record_before_write(norm)
    var err := ResourceSaver.save(res, norm)
    if err != OK:
        error("save_resource: ошибка сохранения %s (код %d)" % [norm, err])
        return false
    _track_modified(norm)
    scan_filesystem()
    return true


func load_resource(path: String) -> Resource:
    var norm := _norm(path)
    if not ResourceLoader.exists(norm):
        error("load_resource: ресурс не найден: " + norm)
        return null
    return ResourceLoader.load(norm)


func create_animation(
    anim_player: AnimationPlayer,
    anim_name: String,
    length: float = 1.0,
    loop: bool = false,
    tracks: Array = []
) -> Animation:
    if anim_player == null:
        error("create_animation: anim_player == null")
        return null

    var lib: AnimationLibrary
    if anim_player.has_animation_library(""):
        lib = anim_player.get_animation_library("")
    else:
        lib = AnimationLibrary.new()
        anim_player.add_animation_library("", lib)

    var anim := Animation.new()
    anim.length = length
    anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE

    for t in tracks:
        if not (t is Dictionary):
            continue
        var track_idx := anim.add_track(t.get("type", Animation.TYPE_VALUE))
        anim.track_set_path(track_idx, NodePath(str(t.get("path", ""))))
        for kf in t.get("keys", []):
            if kf is Array and kf.size() >= 2:
                anim.track_insert_key(track_idx, float(kf[0]), kf[1])

    lib.add_animation(anim_name, anim)
    _check_open_scene_touch(_get_scene_root(anim_player))
    scene_modified = true
    return anim


# ==============================================================================
# 8. СКРИПТЫ И ФАЙЛЫ ПРОЕКТА
# ==============================================================================

func make_dir(path: String) -> bool:
    var norm := _norm(path)
    if DirAccess.dir_exists_absolute(norm):
        return true
    _backup.record_created_dir(norm)
    var err := DirAccess.make_dir_recursive_absolute(norm)
    if err != OK:
        error("make_dir: не удалось создать папку %s (код %d)" % [norm, err])
        return false
    return true


func write_file(path: String, content: String) -> bool:
    var norm := _norm(path)
    make_dir(norm.get_base_dir())
    _backup.record_before_write(norm)
    var f := FileAccess.open(norm, FileAccess.WRITE)
    if f == null:
        error("write_file: невозможно открыть для записи: " + norm)
        return false
    f.store_string(content)
    f.close()
    _track_modified(norm)
    scan_filesystem()
    self.log("Файл записан: " + norm)
    return true


func read_file(path: String) -> String:
    var norm := _norm(path)
    if not FileAccess.file_exists(norm):
        error("read_file: файл не найден: " + norm)
        return ""
    return FileAccess.get_file_as_string(norm)


func file_exists(path: String) -> bool:
    return FileAccess.file_exists(_norm(path))


func list_files(dir_path: String = "res://", recursive: bool = false) -> PackedStringArray:
    var norm := _norm(dir_path)
    var out: PackedStringArray = []
    _scan_dir(norm, recursive, out)
    return out


func _scan_dir(path: String, recursive: bool, out: PackedStringArray) -> void:
    var dir := DirAccess.open(path)
    if dir == null:
        return
    dir.list_dir_begin()
    var fname := dir.get_next()
    while fname != "":
        if not fname.begins_with("."):
            var full := path.path_join(fname)
            if dir.current_is_dir():
                if recursive:
                    _scan_dir(full, true, out)
            else:
                out.append(full)
        fname = dir.get_next()
    dir.list_dir_end()


func delete_file(path: String) -> bool:
    var norm := _norm(path)
    if not FileAccess.file_exists(norm):
        warn("delete_file: файл не существует: " + norm)
        return false
    if _safe_mode:
        if not pending_deletions.has(norm):
            pending_deletions.append(norm)
        warn("Безопасный режим: файл помечен к удалению (потребуется подтверждение): " + norm)
        return true
    return execute_confirmed_deletion(norm)


func execute_confirmed_deletion(res_path: String) -> bool:
    var norm := _norm(res_path)
    if not FileAccess.file_exists(norm):
        return false
    _backup.record_before_delete(norm)
    var err := DirAccess.remove_absolute(norm)
    if err != OK:
        error("Не удалось удалить файл %s (код %d)" % [norm, err])
        return false
    _track_modified(norm + " [удалён]")
    scan_filesystem()
    return true


func create_script(path: String, code: String, validate_gd: bool = true) -> Script:
    var norm := _norm(path)
    if not norm.ends_with(".gd"):
        norm += ".gd"
    if validate_gd:
        var chk: Dictionary = validate_gdscript(code)
        if not bool(chk["ok"]):
            error("create_script отменён (%s): %s" % [norm, str(chk["error"])])
            return null
    if not write_file(norm, code):
        return null
    return ResourceLoader.load(norm, "", ResourceLoader.CACHE_MODE_IGNORE)


func attach_script(node: Node, script_path_or_code: String, save_path: String = "") -> Script:
    if node == null:
        error("attach_script: node == null")
        return null

    var script: Script = null
    if save_path != "":
        script = create_script(save_path, script_path_or_code)
    elif script_path_or_code.strip_edges().ends_with(".gd") and not ("\n" in script_path_or_code):
        script = load_resource(script_path_or_code)
    else:
        var chk: Dictionary = validate_gdscript(script_path_or_code)
        if not bool(chk["ok"]):
            error("attach_script: " + str(chk["error"]))
            return null
        var gd := GDScript.new()
        gd.source_code = script_path_or_code
        gd.reload()
        script = gd

    if script != null:
        node.set_script(script)
        _check_open_scene_touch(_get_scene_root(node))
        scene_modified = true
    return script


# ==============================================================================
# 9. НАСТРОЙКИ ПРОЕКТА, INPUT MAP И ОПТИМИЗАЦИЯ ПОД ANDROID
# ==============================================================================

func optimize_for_android(preset: String = "balanced") -> void:
    match preset.to_lower():
        "performance":
            set_project_setting("rendering/lights_and_shadows/directional_shadow/size", 1024)
            set_project_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 0)
            set_project_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
            set_project_setting("rendering/anti_aliasing/quality/screen_space_aa", 0)
            set_project_setting("rendering/scaling_3d/scale", 0.78)
        "quality":
            set_project_setting("rendering/lights_and_shadows/directional_shadow/size", 2048)
            set_project_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 1)
            set_project_setting("rendering/anti_aliasing/quality/msaa_3d", 1)
            set_project_setting("rendering/scaling_3d/scale", 0.95)
        _:
            set_project_setting("rendering/lights_and_shadows/directional_shadow/size", 1024)
            set_project_setting("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality", 0)
            set_project_setting("rendering/anti_aliasing/quality/msaa_3d", 0)
            set_project_setting("rendering/anti_aliasing/quality/screen_space_aa", 0)
            set_project_setting("rendering/scaling_3d/scale", 0.85)
    self.log("Применён пресет оптимизации Android: " + preset)


func set_project_setting(key: String, value: Variant) -> bool:
    _backup.record_project_setting(key)
    _backup.record_before_write("res://project.godot")
    ProjectSettings.set_setting(key, value)
    var err := ProjectSettings.save()
    if err != OK:
        error("set_project_setting: ошибка сохранения project.godot (код %d)" % err)
        return false
    _track_modified("res://project.godot")
    self.log("Настройка проекта изменена: %s = %s" % [key, str(value)])
    return true


func get_project_setting(key: String, default_value: Variant = null) -> Variant:
    if ProjectSettings.has_setting(key):
        return ProjectSettings.get_setting(key)
    return default_value


func set_main_scene(scene_path: String) -> bool:
    return set_project_setting("application/run/main_scene", _norm(scene_path))


func add_autoload(autoload_name: String, path: String) -> bool:
    return set_project_setting("autoload/" + autoload_name, "*" + _norm(path))


func add_input_action(action_name: String, keys_or_events: Array = [], deadzone: float = 0.5) -> bool:
    var events: Array = []
    for item in keys_or_events:
        if item is InputEvent:
            events.append(item)
        elif item is int:
            var ev := InputEventKey.new()
            ev.physical_keycode = item as Key
            events.append(ev)
        elif item is String:
            var upper: String = str(item).to_upper().strip_edges()
            if upper == "MOUSE_LEFT":
                var mb := InputEventMouseButton.new()
                mb.button_index = MOUSE_BUTTON_LEFT
                events.append(mb)
            elif upper == "MOUSE_RIGHT":
                var mb := InputEventMouseButton.new()
                mb.button_index = MOUSE_BUTTON_RIGHT
                events.append(mb)
            else:
                var kc := OS.find_keycode_from_string(upper)
                if kc != KEY_NONE:
                    var ev := InputEventKey.new()
                    ev.physical_keycode = kc
                    events.append(ev)
                else:
                    warn("add_input_action: не распознана клавиша '%s'" % str(item))

    return set_project_setting("input/" + action_name, {
        "deadzone": deadzone,
        "events": events
    })


# ==============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ВНУТРЕННИЕ МЕТОДЫ
# ==============================================================================

func _check_open_scene_touch(root: Node, created_node: Node = null) -> void:
    var edited := get_edited_scene()
    if edited != null and root == edited:
        _backup.mark_open_scene_modified()
        if created_node != null:
            _backup.record_created_node(created_node)


func _norm(path: String) -> String:
    var p := path.strip_edges()
    if not p.begins_with("res://") and not p.begins_with("user://"):
        p = "res://" + p.trim_prefix("/")
    return p


func _get_scene_root(node: Node) -> Node:
    if node == null:
        return null
    if node.owner != null:
        return node.owner
    var cur := node
    while cur.get_parent() != null and not (cur.get_parent() is SubViewport):
        cur = cur.get_parent()
    return cur


func _ensure_owners(node: Node, root: Node) -> void:
    for child in node.get_children():
        if child.owner == null:
            child.owner = root
        if child.scene_file_path == "":
            _ensure_owners(child, root)


func _track_modified(path: String) -> void:
    if not modified_files.has(path):
        modified_files.append(path)
