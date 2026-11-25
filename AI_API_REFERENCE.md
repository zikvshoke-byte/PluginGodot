# AI Code Executor v2.0 (Godot 4.x Android) — Системная инструкция для ИИ

> **ДЛЯ ВНЕШНЕГО ИИ (ChatGPT / Gemini / Claude):**
> Пользователь разрабатывает игру в **Godot 4.x на Android** через локальный плагин **AI Code Executor v2.0**.
> Плагин исполняет твой GDScript с точкой входа `func run(ai):` прямо внутри редактора Godot, автоматически проверяет синтаксис `.gd`-файлов перед сохранением и ведёт историю откатов по каждому запуску.

---

## 1. ГЛАВНЫЕ ПРАВИЛА (ЭКОНОМИЯ ТОКЕНОВ И НОЛЬ БАГОВ)

1. **ПРАВИЛО ПАТЧЕЙ (PATCH-FIRST) — ОБЯЗАТЕЛЬНО:**
   - **НИКОГДА не переписывай целиком большой файл**, если нужно исправить баг, поменять параметры или добавить 1–2 функции!
   - Для правок существующего скрипта используй:
     - `ai.replace_func(path, "имя_функции", new_code)` — заменяет ровно одну функцию без риска сломать отступы.
     - `ai.patch_file(path, {"уникальный_старый_блок": "новый_блок"})` — делает точечную замену (плагин сам проверит, что блок уникален и что итоговый GDScript компилируется без ошибок!).
     - `ai.insert_in_file(path, "уникальный_якорь", new_code, true)` — вставляет код до/после якоря.
     - `ai.edit_scene(path, func(root): ...)` — меняет существующую `.tscn` без пересборки с нуля.
   - Перезаписывай файл целиком через `ai.create_script()` / `ai.save_scene()` **только** если файл создаётся впервые или пользователь явно попросил «перепиши всё с нуля».

2. **МОДУЛЬНОСТЬ ДЛЯ БОЛЬШИХ ИГР:**
   - Не сваливай всю игру в один скрипт на 800 строк. Разделяй проект на маленькие файлы (`res://scripts/player.gd`, `res://scripts/enemy.gd`, `res://scenes/Player.tscn`, `res://scenes/Level1.tscn`).
   - Если задача большая — предложи делать её короткими шагами (Шаг 1: основа и игрок, Шаг 2: механика/враги, Шаг 3: UI и уровень). Каждый шаг = отдельный чистый лог в плагине.

3. **КОРОТКИЙ И ЧИСТЫЙ КОД:**
   - Используй `ai.build_tree(parent, [...])` для компактной сборки иерархий узлов, циклы `for` для повторяющихся объектов и `ai.optimize_for_android()` одной строкой.
   - Начинай ответ сразу с `func run(ai):` (заголовки `@tool` и `extends RefCounted` плагин добавит сам).

4. **СТРОГИЕ ПРАВИЛА GODOT 4.x И ANDROID (ПРОВЕРЯЙ ПЕРЕД ОТВЕТОМ):**
   - **НЕ используй `:=`** для значений `Variant` (элементы нетипизированных `Array`/`Dictionary`, `JSON.parse_string()`). Пиши `var x = ...` или явный тип `var x: String = str(...)`.
   - **Явные типы `int`/`float`:** не присваивай `float` в `int` напрямую (пиши `int(Engine.get_frames_per_second())`, чтобы не было предупреждений `NARROWING_CONVERSION`).
   - **Гравитация:** не используй `get_gravity()` (ломается на Godot 4.0–4.2), используй константу или `ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)`.
   - **Сенсорное управление Android:** для любых игр обязательно добавляй экранное управление (джойстик / кнопки) в `CanvasLayer`, без привязки к мыши и физической клавиатуре.
   - **Никаких настольных API:** не используй `OS.execute()`, `EditorInterface` как синглтон (бери `ai.get_editor()`), работай только в `res://` и `user://`.
   - **Отступы в многострочных строках `"""..."""`:** внутри генерируемых скриптов используй табы `\t` последовательно, следи за экранированием `\n` внутри строк (пиши `\\n`).

---

## 2. СПРАВОЧНИК API (`ai: AIContext`)

### Точечные патчи и проверка (используй в первую очередь!)
- `ai.patch_file(path, replacements: Dictionary, validate_gd = true) -> bool`
  - Безопасная замена. Если фрагмент не найден или найден больше 1 раза — операция отменяется с ошибкой. Для `.gd` автоматически проверяет компиляцию перед записью!
- `ai.replace_func(path, func_name, new_func_code, validate_gd = true) -> bool`
  - Находит `func <func_name>(` (или `static func`) и аккуратно заменяет всё её тело целиком + проверяет синтаксис.
- `ai.insert_in_file(path, anchor, text_to_insert, after = true, validate_gd = true) -> bool`
  - Вставляет строки сразу после (`after = true`) или перед (`after = false`) уникальным якорем.
- `ai.append_to_file(path, text, validate_gd = true) -> bool` — дописывает в конец файла.
- `ai.validate_gdscript(code) -> Dictionary` — `{"ok": bool, "error": String}`.
- `ai.read_file(path) -> String` / `ai.read_lines(path, from = 1, to = -1) -> String` / `ai.file_exists(path) -> bool`.
- `ai.get_project_summary() -> String` / `ai.get_scene_tree_text(root = null) -> String`.

### Сцены и компактная сборка
- `ai.create_scene(root_type = "Node3D", root_name = "Main") -> Node`
- `ai.edit_scene(path, callback: Callable, open_in_editor = true) -> bool`
  - Загружает `.tscn` (или берёт открытую), передаёт `root` в `callback`, сохраняет.
- `ai.save_scene(root, path, open_in_editor = true) -> bool` / `ai.save_current_scene() -> bool`
- `ai.load_scene(path) -> Node` / `ai.get_edited_scene() -> Node` / `ai.open_scene(path)`
- `ai.build_tree(parent, specs: Array) -> Array[Node]`
  - Декларативная сборка. Ключи словаря: `type` (или `scene`, или `box`: `Vector3`), `name`, `pos`, `rot` (в градусах), `scale`, `props`, `mat`, `col` (bool для `box`), `script`, `group`/`groups`, `children`.

### Узлы, физика, 3D, 2D, UI
- `ai.add_node(parent, type_name, name = "", props = {}) -> Node`
- `ai.instance_scene(parent, scene_path, name = "", props = {}) -> Node`
- `ai.find_node(root, name_or_path) -> Node` / `ai.get_nodes_by_type(root, type_name) -> Array[Node]`
- `ai.set_props(obj, props)` / `ai.set_transform_3d(n, pos, rot_deg, scl)` / `ai.set_transform_2d(n, pos, rot_deg, scl)`
- `ai.rename_node(n, name)` / `ai.reparent_node(n, new_parent)` / `ai.remove_node(n)`
- `ai.connect_signal(src, sig, dst, method)` / `ai.add_to_group(n, group)` / `ai.set_collision_layers(n, layers, masks)`
- **3D:** `create_box(p, name, size, pos, mat, with_col)`, `create_mesh(...)`, `create_csg(...)`, `create_light(...)`, `create_camera_3d(...)`, `create_environment(...)`, `create_physics_3d(...)`, `create_collision_polygon_3d(...)`, `create_particles_3d(...)`.
- **2D / UI:** `create_sprite_2d(...)`, `create_camera_2d(...)`, `create_physics_2d(...)`, `create_collision_polygon_2d(...)`, `create_particles_2d(...)`, `create_ui(p, type, name, props, anchors_preset)`.

### Материалы, скрипты, файлы и настройки
- `ai.create_material(props)` (`color`, `texture`, `metallic`, `roughness`, `emission`, `emission_energy`, `transparent`) / `ai.set_material(node, mat_or_props)`
- `ai.create_shader_material(code, uniforms = {}, save_path = "")`
- `ai.create_animation(anim_player, name, length, loop, tracks)`
- `ai.create_script(path, code, validate_gd = true) -> Script` / `ai.attach_script(node, path_or_code, save_path = "")`
- `ai.write_file(path, content)` / `ai.make_dir(path)` / `ai.list_files(dir, recursive)` / `ai.delete_file(path)`
- `ai.optimize_for_android(preset = "balanced")` (`"performance"`, `"balanced"`, `"quality"`)
- `ai.set_project_setting(key, val)` / `ai.set_main_scene(path)` / `ai.add_autoload(name, path)` / `ai.add_input_action(name, keys)`
- `ai.log(msg)` / `ai.warn(msg)` / `ai.error(msg)`

---

## 3. ЭТАЛОННЫЕ КОРОТКИЕ ПРИМЕРЫ

### Пример 1: Точечный патч бага (вместо переписывания всего файла!)
```gdscript
func run(ai):
    # Заменяем только сломанную функцию — 8 строк вместо 400!
    ai.replace_func("res://scripts/player.gd", "_on_jump_pressed", """func _on_jump_pressed() -> void:
\tif is_on_floor():
\t\tvelocity.y = JUMP_VELOCITY * 1.15""")

    # Точечно меняем константу
    ai.patch_file("res://scripts/player.gd", {
        "const SPEED: float = 6.8": "const SPEED: float = 8.0"
    })
```

### Пример 2: Точечное изменение существующей сцены
```gdscript
func run(ai):
    ai.edit_scene("res://scenes/Main.tscn", func(root):
        ai.create_box(root, "NewPlatform", Vector3(4, 0.5, 4), Vector3(0, 2.5, -6), {"color": Color(0.2, 0.8, 0.4)}, true)
        ai.log("Платформа добавлена в сцену!")
    )
```

### Пример 3: Компактное создание 3D-сцены через `build_tree`
```gdscript
func run(ai):
    ai.optimize_for_android("balanced")
    var scene = ai.create_scene("Node3D", "Arena")
    ai.create_environment(scene)
    ai.create_light(scene, "directional", Vector3(0, 12, 0), Vector3(-45, 30, 0))

    ai.build_tree(scene, [
        {"box": Vector3(20, 0.5, 20), "name": "Floor", "pos": Vector3(0, -0.25, 0), "mat": {"color": Color(0.35, 0.4, 0.45)}},
        {"box": Vector3(20, 3, 0.5), "name": "WallN", "pos": Vector3(0, 1.5, -10), "mat": {"color": Color(0.85, 0.85, 0.9)}},
        {"type": "Camera3D", "name": "Cam", "pos": Vector3(0, 6, 12), "rot": Vector3(-25, 0, 0)}
    ])

    ai.save_scene(scene, "res://scenes/Arena.tscn")
    ai.set_main_scene("res://scenes/Arena.tscn")
```