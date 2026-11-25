@tool
extends Control

const AIBackupManagerScript = preload("res://addons/ai_code_executor/ai_backup_manager.gd")
const AIExecutorScript = preload("res://addons/ai_code_executor/ai_executor.gd")

var _plugin: EditorPlugin
var _backup: AIBackupManager
var _executor: AIExecutor

var _tabs: TabContainer

# Вкладка «Код»
var _code_edit: CodeEdit
var _log_view: RichTextLabel
var _safe_mode_cb: CheckBox
var _btn_undo: Button

# Вкладка «Логи» (сенсорные карточки с ярко-зелёным выделением)
var _logs_tab: Control
var _logs_vbox: VBoxContainer
var _selected_log_ids: Array[String] = []
var _log_item_buttons: Dictionary = {}
var _log_details: RichTextLabel
var _btn_log_select_all: Button
var _btn_log_rename: Button
var _btn_log_copy: Button
var _btn_log_load: Button
var _btn_log_merge: Button
var _btn_log_delete: Button
var _style_card_normal: StyleBoxFlat
var _style_card_selected: StyleBoxFlat

# Диалоги
var _confirm_del_files_dlg: ConfirmationDialog
var _pending_delete_paths: Array[String] = []

var _rename_dlg: ConfirmationDialog
var _rename_edit: LineEdit
var _rename_target_id: String = ""

var _confirm_del_log_dlg: ConfirmationDialog
var _delete_log_target_id: String = ""

var _scripts_dlg: ConfirmationDialog
var _scripts_box: VBoxContainer
var _script_checks: Array[CheckBox] = []


func setup(plugin: EditorPlugin) -> void:
    _plugin = plugin
    _backup = AIBackupManagerScript.new(_plugin)
    _executor = AIExecutorScript.new(_plugin, _backup)


func _ready() -> void:
    custom_minimum_size = Vector2(0, 320)
    size_flags_horizontal = Control.SIZE_EXPAND_FILL
    size_flags_vertical = Control.SIZE_EXPAND_FILL
    _init_card_styles()
    _build_ui()
    _refresh_logs_ui()
    _append_log("INFO", "AI Code Executor 2.0 готов. Вставьте код от ИИ и нажмите ▶ Выполнить.")


func _init_card_styles() -> void:
    _style_card_normal = StyleBoxFlat.new()
    _style_card_normal.bg_color = Color(0.16, 0.18, 0.22, 1.0)
    _style_card_normal.border_color = Color(0.28, 0.31, 0.38, 1.0)
    _style_card_normal.set_border_width_all(1)
    _style_card_normal.set_corner_radius_all(6)
    _style_card_normal.content_margin_left = 10
    _style_card_normal.content_margin_right = 10

    _style_card_selected = StyleBoxFlat.new()
    _style_card_selected.bg_color = Color(0.12, 0.46, 0.20, 1.0)
    _style_card_selected.border_color = Color(0.38, 1.0, 0.50, 1.0)
    _style_card_selected.set_border_width_all(2)
    _style_card_selected.set_corner_radius_all(6)
    _style_card_selected.content_margin_left = 10
    _style_card_selected.content_margin_right = 10


func _build_ui() -> void:
    var root_vbox := VBoxContainer.new()
    root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(root_vbox)

    _tabs = TabContainer.new()
    _tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
    root_vbox.add_child(_tabs)

    _build_code_tab()
    _build_logs_tab()
    _build_dialogs()


func _make_btn(text: String, cb: Callable, min_w: int = 0) -> Button:
    var b := Button.new()
    b.text = text
    b.custom_minimum_size = Vector2(min_w, 42)
    b.focus_mode = Control.FOCUS_NONE
    b.pressed.connect(cb)
    return b


func _create_gdscript_highlighter() -> CodeHighlighter:
    var hl := CodeHighlighter.new()
    hl.number_color = Color(0.63, 1.0, 0.88)
    hl.symbol_color = Color(0.67, 0.78, 1.0)
    hl.function_color = Color(0.34, 0.70, 1.0)
    hl.member_variable_color = Color(0.73, 0.88, 1.0)

    var kw_color := Color(1.0, 0.44, 0.52)
    var keywords := [
        "func", "var", "const", "if", "elif", "else", "for", "while",
        "return", "pass", "break", "continue", "match", "in", "and",
        "or", "not", "true", "false", "null", "extends", "class_name",
        "signal", "enum", "static", "await", "as", "is", "self", "super",
        "preload", "load"
    ]
    for kw in keywords:
        hl.add_keyword_color(kw, kw_color)

    var type_color := Color(0.26, 0.96, 0.74)
    var types := [
        "void", "bool", "int", "float", "String", "Vector2", "Vector3",
        "Vector2i", "Vector3i", "Color", "Array", "Dictionary", "Node",
        "Node2D", "Node3D", "Control", "Button", "Label", "Camera3D",
        "MeshInstance3D", "CharacterBody3D", "RigidBody3D", "StaticBody3D",
        "Area3D", "SpringArm3D", "Skeleton3D", "AnimationPlayer", "Transform3D",
        "Basis", "Quaternion", "PackedScene", "ShaderMaterial", "StandardMaterial3D",
        "Script", "NodePath", "PackedStringArray", "RID", "InputEvent"
    ]
    for tp in types:
        hl.add_keyword_color(tp, type_color)

    hl.add_keyword_color("ai", Color(1.0, 0.78, 0.35))

    var str_color := Color(1.0, 0.93, 0.63)
    hl.add_color_region("\"", "\"", str_color, false)
    hl.add_color_region("'", "'", str_color, false)
    hl.add_color_region("#", "", Color(0.55, 0.60, 0.66), true)
    return hl


func _build_code_tab() -> void:
    var code_tab := VBoxContainer.new()
    code_tab.name = "💻 Код"
    code_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    code_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _tabs.add_child(code_tab)

    var toolbar := HFlowContainer.new()
    toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    toolbar.add_theme_constant_override("h_separation", 6)
    toolbar.add_theme_constant_override("v_separation", 6)
    code_tab.add_child(toolbar)

    toolbar.add_child(_make_btn("📋 Вставить", _on_paste))
    toolbar.add_child(_make_btn("✓ Проверить", _on_validate))
    toolbar.add_child(_make_btn("🔍 План", _on_plan))

    var btn_run := _make_btn("▶ Выполнить", _on_execute)
    btn_run.modulate = Color(0.55, 1.0, 0.65)
    toolbar.add_child(btn_run)

    _btn_undo = _make_btn("↶ Отменить", _on_undo)
    toolbar.add_child(_btn_undo)

    toolbar.add_child(_make_btn("📤 Контекст ИИ", _on_copy_context))
    toolbar.add_child(_make_btn("📦 Скрипты", _on_open_scripts_dialog))
    toolbar.add_child(_make_btn("🗑 Очистить", _on_clear_code))

    _safe_mode_cb = CheckBox.new()
    _safe_mode_cb.text = "Безопасный режим"
    _safe_mode_cb.button_pressed = true
    _safe_mode_cb.custom_minimum_size = Vector2(0, 42)
    toolbar.add_child(_safe_mode_cb)

    var split := VSplitContainer.new()
    split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    split.size_flags_vertical = Control.SIZE_EXPAND_FILL
    code_tab.add_child(split)

    _code_edit = CodeEdit.new()
    _code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _code_edit.custom_minimum_size = Vector2(0, 140)
    _code_edit.gutters_draw_line_numbers = true
    _code_edit.indent_automatic = true
    _code_edit.auto_brace_completion_enabled = true
    _code_edit.syntax_highlighter = _create_gdscript_highlighter()
    _code_edit.placeholder_text = "Вставьте сюда код от ИИ (начинается с func run(ai):)..."
    split.add_child(_code_edit)

    _log_view = RichTextLabel.new()
    _log_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _log_view.custom_minimum_size = Vector2(0, 90)
    _log_view.bbcode_enabled = true
    _log_view.scroll_following = true
    _log_view.selection_enabled = true
    split.add_child(_log_view)


func _build_logs_tab() -> void:
    _logs_tab = VBoxContainer.new()
    _logs_tab.name = "📜 Логи (0)"
    _logs_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _logs_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _tabs.add_child(_logs_tab)

    var top_bar := HFlowContainer.new()
    top_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    top_bar.add_theme_constant_override("h_separation", 6)
    top_bar.add_theme_constant_override("v_separation", 6)
    _logs_tab.add_child(top_bar)

    _btn_log_select_all = _make_btn("☑ Все", _on_toggle_select_all_logs)
    top_bar.add_child(_btn_log_select_all)

    _btn_log_rename = _make_btn("✏ Переименовать", _on_rename_selected_log)
    top_bar.add_child(_btn_log_rename)

    _btn_log_copy = _make_btn("📋 Копировать код", _on_copy_selected_log_code)
    top_bar.add_child(_btn_log_copy)

    _btn_log_load = _make_btn("↩ В редактор", _on_load_selected_log_code)
    top_bar.add_child(_btn_log_load)

    _btn_log_merge = _make_btn("🔗 Совместить", _on_merge_selected_logs)
    _btn_log_merge.modulate = Color(0.55, 1.0, 0.65)
    top_bar.add_child(_btn_log_merge)

    _btn_log_delete = _make_btn("🗑 Удалить лог", _on_ask_delete_selected_log)
    _btn_log_delete.modulate = Color(1.0, 0.65, 0.65)
    top_bar.add_child(_btn_log_delete)

    var split := HSplitContainer.new()
    split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    split.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _logs_tab.add_child(split)

    var logs_scroll := ScrollContainer.new()
    logs_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    logs_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    logs_scroll.custom_minimum_size = Vector2(245, 140)
    split.add_child(logs_scroll)

    _logs_vbox = VBoxContainer.new()
    _logs_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _logs_vbox.add_theme_constant_override("separation", 6)
    logs_scroll.add_child(_logs_vbox)

    _log_details = RichTextLabel.new()
    _log_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _log_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _log_details.bbcode_enabled = true
    _log_details.selection_enabled = true
    _log_details.text = "Нажимайте на логи слева (выделенные станут зелёными), чтобы совместить их в один чистый код."
    split.add_child(_log_details)


func _build_dialogs() -> void:
    _confirm_del_files_dlg = ConfirmationDialog.new()
    _confirm_del_files_dlg.title = "Подтверждение удаления файлов"
    _confirm_del_files_dlg.confirmed.connect(_on_confirm_pending_deletions)
    add_child(_confirm_del_files_dlg)

    _rename_dlg = ConfirmationDialog.new()
    _rename_dlg.title = "Переименовать лог"
    _rename_edit = LineEdit.new()
    _rename_edit.placeholder_text = "Новое название лога..."
    _rename_edit.custom_minimum_size = Vector2(280, 40)
    _rename_dlg.add_child(_rename_edit)
    _rename_dlg.confirmed.connect(_on_confirm_rename_log)
    add_child(_rename_dlg)

    _confirm_del_log_dlg = ConfirmationDialog.new()
    _confirm_del_log_dlg.title = "Удалить и откатить лог?"
    _confirm_del_log_dlg.confirmed.connect(_on_confirm_delete_log)
    add_child(_confirm_del_log_dlg)

    _scripts_dlg = ConfirmationDialog.new()
    _scripts_dlg.title = "Скопировать скрипты для ИИ"
    _scripts_dlg.ok_button_text = "📋 Скопировать выбранное"
    _scripts_dlg.min_size = Vector2i(360, 400)
    var scroll := ScrollContainer.new()
    scroll.custom_minimum_size = Vector2(340, 320)
    _scripts_box = VBoxContainer.new()
    _scripts_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    scroll.add_child(_scripts_box)
    _scripts_dlg.add_child(scroll)
    _scripts_dlg.confirmed.connect(_on_confirm_copy_scripts)
    add_child(_scripts_dlg)


# ==============================================================================
# ДЕЙСТВИЯ ВКЛАДКИ «КОД»
# ==============================================================================

func _on_paste() -> void:
    var clip: String = DisplayServer.clipboard_get()
    if clip.strip_edges().is_empty():
        _append_log("WARN", "Буфер обмена пуст.")
        return
    _code_edit.text = _strip_markdown_fences(clip)
    _append_log("INFO", "Код вставлен из буфера обмена (%d строк)." % _code_edit.get_line_count())


func _strip_markdown_fences(txt: String) -> String:
    var s: String = txt.strip_edges()
    if s.begins_with("```"):
        var first_nl: int = s.find("\n")
        if first_nl != -1:
            s = s.substr(first_nl + 1)
    if s.ends_with("```"):
        s = s.left(s.length() - 3)
    return s.strip_edges()


func _on_clear_code() -> void:
    _code_edit.text = ""
    _log_view.clear()


func _on_validate() -> void:
    if _executor == null:
        return
    var res: Dictionary = _executor.validate_code(_code_edit.text)
    if bool(res.get("ok", false)):
        _append_log("OK", str(res.get("message", "OK")))
    else:
        _append_log("ERROR", str(res.get("message", "Ошибка проверки")))


func _on_plan() -> void:
    if _executor == null:
        return
    var plan: Dictionary = _executor.analyze_plan(_code_edit.text)
    _append_log("INFO", "=== ПЛАН ДЕЙСТВИЙ ===")
    _append_log("INFO", "Операций с узлами: %d | Сцен: %d | Файлов: %d | Настроек: %d | Удалений: %d" % [
        int(plan.get("node_ops_count", 0)),
        (plan.get("scenes", []) as Array).size(),
        (plan.get("files", []) as Array).size(),
        (plan.get("settings", []) as Array).size(),
        (plan.get("deletions", []) as Array).size()
    ])
    for w in plan.get("warnings", []):
        _append_log("WARN", str(w))


func _on_execute() -> void:
    if _executor == null:
        return
    var raw: String = _strip_markdown_fences(_code_edit.text)
    _code_edit.text = raw

    var rep: Dictionary = _executor.execute_code(raw, _safe_mode_cb.button_pressed)
    if str(rep.get("error", "")) != "":
        _append_log("ERROR", str(rep["error"]))
        return

    for entry in rep.get("logs", []):
        if entry is Dictionary:
            _append_log(str(entry.get("level", "INFO")), str(entry.get("msg", "")))

    var ms: int = int(rep.get("duration_ms", 0))
    var saved_name: String = str(rep.get("saved_log_name", ""))
    if bool(rep.get("ok", false)):
        var suffix: String = (" | Сохранено в лог «%s»" % saved_name) if saved_name != "" else ""
        _append_log("OK", "Выполнено успешно за %d мс.%s" % [ms, suffix])
    else:
        _append_log("WARN", "Завершено с ошибками за %d мс." % ms)

    var pending: Array = rep.get("pending_deletions", [])
    if not pending.is_empty():
        _pending_delete_paths.clear()
        var msg_lines: PackedStringArray = ["Безопасный режим заблокировал удаление следующих файлов:\n"]
        for p in pending:
            var ps: String = str(p)
            _pending_delete_paths.append(ps)
            msg_lines.append("• " + ps)
        msg_lines.append("\nУдалить их сейчас?")
        _confirm_del_files_dlg.dialog_text = "\n".join(msg_lines)
        _confirm_del_files_dlg.popup_centered()

    _refresh_logs_ui()


func _on_undo() -> void:
    if _backup == null:
        return
    var res: Dictionary = _backup.undo_last_session()
    if bool(res.get("ok", false)):
        _append_log("OK", str(res.get("message", "Откат выполнен.")))
    else:
        _append_log("WARN", str(res.get("message", "Нечего отменять.")))
    _refresh_logs_ui()


func _on_copy_context() -> void:
    var tmp_ai := AIContext.new(_plugin, _backup, true)
    var summary: String = tmp_ai.get_project_summary(80)
    DisplayServer.clipboard_set(summary)
    _append_log("OK", "Контекст проекта + Карта кода (Repo Map) скопированы в буфер обмена (%d символов)." % summary.length())


func _on_open_scripts_dialog() -> void:
    for ch in _scripts_box.get_children():
        ch.queue_free()
    _script_checks.clear()

    var ref_path: String = "res://addons/ai_code_executor/AI_API_REFERENCE.md"
    if FileAccess.file_exists(ref_path):
        var cb_ref := CheckBox.new()
        cb_ref.text = "📘 AI_API_REFERENCE.md (инструкция для ИИ)"
        cb_ref.set_meta("file_path", ref_path)
        cb_ref.button_pressed = false
        _scripts_box.add_child(cb_ref)
        _script_checks.append(cb_ref)

    var tmp_ai := AIContext.new(_plugin, _backup, true)
    var all_files: PackedStringArray = tmp_ai.list_files("res://", true)
    for f in all_files:
        if f.begins_with("res://addons/ai_code_executor/"):
            continue
        if f.ends_with(".gd") or f.ends_with(".gdshader"):
            var cb := CheckBox.new()
            cb.text = f.replace("res://", "")
            cb.set_meta("file_path", f)
            cb.button_pressed = true
            _scripts_box.add_child(cb)
            _script_checks.append(cb)

    _scripts_dlg.popup_centered()


func _on_confirm_copy_scripts() -> void:
    var parts: PackedStringArray = []
    var count: int = 0
    for cb in _script_checks:
        if is_instance_valid(cb) and cb.button_pressed:
            var fpath: String = str(cb.get_meta("file_path", ""))
            if fpath != "" and FileAccess.file_exists(fpath):
                var content: String = FileAccess.get_file_as_string(fpath)
                parts.append("=== FILE: %s ===\n%s\n" % [fpath, content])
                count += 1

    if count == 0:
        _append_log("WARN", "Не выбрано ни одного файла.")
        return

    var joined: String = "\n".join(parts)
    DisplayServer.clipboard_set(joined)
    _append_log("OK", "Скопировано файлов: %d (%d символов). Вставьте в чат с ИИ." % [count, joined.length()])


func _on_confirm_pending_deletions() -> void:
    var tmp_ai := AIContext.new(_plugin, _backup, false)
    for p in _pending_delete_paths:
        tmp_ai.delete_file(p)
    _pending_delete_paths.clear()
    _append_log("OK", "Запрошенные файлы удалены.")
    _refresh_logs_ui()


# ==============================================================================
# ДЕЙСТВИЯ ВКЛАДКИ «ЛОГИ» (СЕНСОРНОЕ ВЫДЕЛЕНИЕ ЯРКО-ЗЕЛЁНЫМ + СОВМЕЩЕНИЕ)
# ==============================================================================

func _refresh_logs_ui() -> void:
    if _backup == null:
        return
    var sessions: Array[Dictionary] = _backup.get_sessions()
    var count: int = sessions.size()

    if _tabs and _logs_tab:
        var tab_idx: int = _tabs.get_tab_idx_from_control(_logs_tab)
        if tab_idx >= 0:
            _tabs.set_tab_title(tab_idx, "📜 Логи (%d)" % count)

    if _btn_undo:
        _btn_undo.disabled = (count == 0)
        _btn_undo.text = "↶ Отменить (%d)" % count if count > 0 else "↶ Отменить"

    if _logs_vbox == null:
        return

    var valid_ids: Dictionary = {}
    for s in sessions:
        valid_ids[str(s.get("id", ""))] = true
    for i in range(_selected_log_ids.size() - 1, -1, -1):
        if not valid_ids.has(_selected_log_ids[i]):
            _selected_log_ids.remove_at(i)

    for ch in _logs_vbox.get_children():
        ch.queue_free()
    _log_item_buttons.clear()

    for i in range(count):
        var s: Dictionary = sessions[i]
        var sid: String = str(s.get("id", ""))
        var sname: String = str(s.get("name", str(i + 1)))
        var ts: String = str(s.get("timestamp", ""))
        var c_cnt: int = (s.get("created_files", []) as Array).size()
        var m_cnt: int = (s.get("backed_up_files", {}) as Dictionary).size()

        var btn := Button.new()
        btn.custom_minimum_size = Vector2(0, 48)
        btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
        btn.focus_mode = Control.FOCUS_NONE
        btn.pressed.connect(_on_toggle_log_card.bind(sid))
        _logs_vbox.add_child(btn)
        _log_item_buttons[sid] = {
            "btn": btn,
            "base_label": "#%s  [%s] (+%d / ~%d)" % [sname, ts.get_slice(" ", 1), c_cnt, m_cnt]
        }

    _apply_log_cards_visuals()
    _update_log_details_view()
    if count == 0:
        _log_details.text = "Пока нет сохранённых логов. Выполните любой код во вкладке «💻 Код»."


func _on_toggle_log_card(sid: String) -> void:
    if _selected_log_ids.has(sid):
        _selected_log_ids.erase(sid)
    else:
        _selected_log_ids.append(sid)
    _apply_log_cards_visuals()
    _update_log_details_view()


func _on_toggle_select_all_logs() -> void:
    if _backup == null:
        return
    var sessions: Array[Dictionary] = _backup.get_sessions()
    if sessions.is_empty():
        return
    if _selected_log_ids.size() == sessions.size():
        _selected_log_ids.clear()
    else:
        _selected_log_ids.clear()
        for s in sessions:
            _selected_log_ids.append(str(s.get("id", "")))
    _apply_log_cards_visuals()
    _update_log_details_view()


func _apply_log_cards_visuals() -> void:
    for sid in _log_item_buttons.keys():
        var info: Dictionary = _log_item_buttons[sid]
        var btn: Button = info["btn"]
        var base_lbl: String = str(info["base_label"])
        if not is_instance_valid(btn):
            continue
        var is_sel: bool = _selected_log_ids.has(str(sid))
        var st: StyleBoxFlat = _style_card_selected if is_sel else _style_card_normal
        btn.add_theme_stylebox_override("normal", st)
        btn.add_theme_stylebox_override("hover", st)
        btn.add_theme_stylebox_override("pressed", st)
        if is_sel:
            btn.text = "✔ " + base_lbl
            btn.add_theme_color_override("font_color", Color(0.88, 1.0, 0.90))
        else:
            btn.text = "   " + base_lbl
            btn.add_theme_color_override("font_color", Color(0.90, 0.92, 0.96))


func _get_selected_session_ids() -> Array[String]:
    return _selected_log_ids.duplicate()


func _update_log_buttons_state() -> void:
    var sel_count: int = _selected_log_ids.size()
    var total_count: int = _backup.get_undo_count() if _backup else 0
    var one: bool = (sel_count == 1)
    var multi: bool = (sel_count >= 2)

    if _btn_log_select_all:
        _btn_log_select_all.disabled = (total_count == 0)
        _btn_log_select_all.text = "☐ Снять все" if (total_count > 0 and sel_count == total_count) else "☑ Все"
    if _btn_log_rename:
        _btn_log_rename.disabled = not one
    if _btn_log_copy:
        _btn_log_copy.disabled = not one
    if _btn_log_load:
        _btn_log_load.disabled = not one
    if _btn_log_delete:
        _btn_log_delete.disabled = not one
    if _btn_log_merge:
        _btn_log_merge.disabled = not multi
        _btn_log_merge.text = ("🔗 Совместить (%d)" % sel_count) if multi else "🔗 Совместить"


func _update_log_details_view() -> void:
    _update_log_buttons_state()
    var sel: Array[String] = _get_selected_session_ids()
    if sel.is_empty():
        _log_details.text = "Нажмите на любой лог слева (выделение станет ярко-зелёным).\nВыделите 2 или более логов, чтобы совместить их в один чистый скрипт."
        return
    if sel.size() >= 2:
        _log_details.text = "[color=#7CFC90][b]Выделено логов: %d[/b][/color]\n\nНажмите [b]«🔗 Совместить (%d)»[/b], чтобы собрать из актуальных файлов один чистый скрипт [code]func run(ai):[/code] без промежуточных багов и с единым откатом." % [sel.size(), sel.size()]
        return

    var s: Dictionary = _backup.get_session_by_id(sel[0])
    if s.is_empty():
        return

    var lines: PackedStringArray = []
    lines.append("[b]Лог «%s»[/b]  (%s)" % [str(s.get("name", "")), str(s.get("timestamp", ""))])

    var cfiles: Array = s.get("created_files", [])
    if not cfiles.is_empty():
        lines.append("\n[color=#7CFC90]Созданные файлы (%d):[/color]" % cfiles.size())
        for f in cfiles:
            lines.append("  + " + str(f))

    var bfiles: Dictionary = s.get("backed_up_files", {})
    if not bfiles.is_empty():
        lines.append("\n[color=#FFD56B]Изменённые файлы (%d):[/color]" % bfiles.size())
        for f in bfiles.keys():
            lines.append("  ~ " + str(f))

    var dfiles: Dictionary = s.get("deleted_files", {})
    if not dfiles.is_empty():
        lines.append("\n[color=#FF8888]Удалённые файлы (%d):[/color]" % dfiles.size())
        for f in dfiles.keys():
            lines.append("  - " + str(f))

    var ps_map: Dictionary = s.get("project_settings", {})
    if not ps_map.is_empty():
        lines.append("\n[color=#88CCFF]Настройки проекта (%d):[/color]" % ps_map.size())
        for k in ps_map.keys():
            lines.append("  • " + str(k))

    var code_str: String = str(s.get("code", ""))
    lines.append("\n[color=#AAAAAA]Размер кода: %d символов (%d строк)[/color]" % [code_str.length(), code_str.split("\n").size()])
    _log_details.text = "\n".join(lines)


func _on_rename_selected_log() -> void:
    var sel: Array[String] = _get_selected_session_ids()
    if sel.size() != 1:
        return
    var s: Dictionary = _backup.get_session_by_id(sel[0])
    if s.is_empty():
        return
    _rename_target_id = sel[0]
    _rename_edit.text = str(s.get("name", ""))
    _rename_dlg.popup_centered()
    _rename_edit.grab_focus()
    _rename_edit.select_all()


func _on_confirm_rename_log() -> void:
    if _rename_target_id == "":
        return
    if _backup.rename_session(_rename_target_id, _rename_edit.text):
        _append_log("OK", "Лог переименован в «%s»." % _rename_edit.text.strip_edges())
        _refresh_logs_ui()
    _rename_target_id = ""


func _on_copy_selected_log_code() -> void:
    var sel: Array[String] = _get_selected_session_ids()
    if sel.size() != 1:
        return
    var s: Dictionary = _backup.get_session_by_id(sel[0])
    if s.is_empty():
        return
    var code_str: String = str(s.get("code", ""))
    DisplayServer.clipboard_set(code_str)
    _append_log("OK", "Код лога «%s» скопирован в буфер обмена (%d символов)." % [str(s.get("name", "")), code_str.length()])


func _on_load_selected_log_code() -> void:
    var sel: Array[String] = _get_selected_session_ids()
    if sel.size() != 1:
        return
    var s: Dictionary = _backup.get_session_by_id(sel[0])
    if s.is_empty():
        return
    _code_edit.text = str(s.get("code", ""))
    _tabs.current_tab = 0
    _append_log("INFO", "Код лога «%s» загружен в редактор." % str(s.get("name", "")))


func _on_merge_selected_logs() -> void:
    var sel: Array[String] = _get_selected_session_ids()
    if sel.size() < 2:
        _append_log("WARN", "Выделите минимум 2 лога для совмещения.")
        return
    var res: Dictionary = _backup.merge_sessions(sel)
    if bool(res.get("ok", false)):
        _selected_log_ids.clear()
        var new_id: String = str(res.get("session_id", ""))
        if new_id != "":
            _selected_log_ids.append(new_id)
        _append_log("OK", str(res.get("message", "Логи совмещены.")))
        _refresh_logs_ui()
    else:
        _append_log("ERROR", str(res.get("message", "Ошибка совмещения логов.")))


func _on_ask_delete_selected_log() -> void:
    var sel: Array[String] = _get_selected_session_ids()
    if sel.size() != 1:
        return
    var s: Dictionary = _backup.get_session_by_id(sel[0])
    if s.is_empty():
        return
    _delete_log_target_id = sel[0]
    _confirm_del_log_dlg.dialog_text = "Удалить лог «%s»?\nВсе файлы, скрипты, сцены, папки и настройки, созданные этим логом, будут полностью удалены и откатаны!" % str(s.get("name", ""))
    _confirm_del_log_dlg.popup_centered()


func _on_confirm_delete_log() -> void:
    if _delete_log_target_id == "":
        return
    var res: Dictionary = _backup.undo_session_by_id(_delete_log_target_id)
    _selected_log_ids.erase(_delete_log_target_id)
    _delete_log_target_id = ""
    if bool(res.get("ok", false)):
        _append_log("OK", str(res.get("message", "Лог удалён.")))
    else:
        _append_log("ERROR", str(res.get("message", "Не удалось удалить лог.")))
    _refresh_logs_ui()


func _append_log(level: String, msg: String) -> void:
    if _log_view == null:
        return
    var color_hex := "#DDDDDD"
    match level:
        "OK":
            color_hex = "#7CFC90"
        "WARN":
            color_hex = "#FFD56B"
        "ERROR":
            color_hex = "#FF7070"
        "INFO":
            color_hex = "#9AD0FF"
    _log_view.append_text("[color=%s][%s][/color] %s\n" % [color_hex, level, msg])
