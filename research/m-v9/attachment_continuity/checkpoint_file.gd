extends RefCounted
## File publication only. No world mutation or second checkpoint format.

static func write_new(path: String, image: Dictionary) -> Dictionary:
	return _publish(path, image, false)

static func write_text_new(path: String, text: String) -> Dictionary:
	return _publish(path, text.to_utf8_buffer(), true)

static func _publish(path: String, image: Variant, raw: bool) -> Dictionary:
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path):
		return {"ok": false, "error": "checkpoint_target_exists"}
	var staging: String = path + ".saving"
	# Atomic directory reservation serializes cooperating save writers.
	if DirAccess.make_dir_absolute(staging) != OK:
		return {"ok": false, "error": "checkpoint_path_busy_or_unavailable"}
	var part: String = staging.path_join("checkpoint.part")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(staging)
		return {"ok": false, "error": "checkpoint_target_exists"}
	var file: FileAccess = FileAccess.open(part, FileAccess.WRITE)
	if file == null:
		DirAccess.remove_absolute(staging)
		return {"ok": false, "error": "checkpoint_file_unavailable"}
	if raw:
		file.store_buffer(image)
	else:
		file.store_var(image, false)
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK or FileAccess.file_exists(path):
		DirAccess.remove_absolute(part)
		DirAccess.remove_absolute(staging)
		return {"ok": false, "error": "checkpoint_write_failed_or_target_exists"}
	if DirAccess.rename_absolute(part, path) != OK:
		DirAccess.remove_absolute(part)
		DirAccess.remove_absolute(staging)
		return {"ok": false, "error": "checkpoint_publish_failed"}
	DirAccess.remove_absolute(staging)
	return {"ok": true}
