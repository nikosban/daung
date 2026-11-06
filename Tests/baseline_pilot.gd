extends RefCounted
## Test helper (not part of the game): loads an earlier commit's pilot and that commit's own frigate movement profile from
## Git, so a test can run the old pilot on the data it was written for. Used by the Tests/*_test.gd scripts through
## preload(); requires the git command and a checkout with that commit. Files are written under user://baseline_<commit>.


## The pilot script at `commit`, typed against that commit's MovementProfile script (renamed OldProfile) so it can run
## beside the current ShipPilot with the old profile. Null when it cannot be loaded.
static func load_pilot(commit: String) -> GDScript:
	var folder := _prepare_profile_script(commit)
	var source := _git_show(commit, "Movement/pilot.gd")
	if folder == "" or source == "":
		return null
	source = source.replace("class_name ShipPilot", "")
	source = RegEx.create_from_string("\\bMovementProfile\\b").sub(source, "OldProfile", true)
	source = source.replace("extends RefCounted", "extends RefCounted\n\nconst OldProfile = preload(\"%s/movement_profile.gd\")" % folder)
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return null
	return script


## The frigate movement profile at `commit`, loaded with that commit's MovementProfile script. Null when it cannot be
## loaded.
static func load_profile(commit: String) -> Resource:
	var folder := _prepare_profile_script(commit)
	var data := _git_show(commit, "Movement/Profiles/frigate_movement_profile.tres")
	if folder == "" or data == "":
		return null
	var lines := data.split("\n")
	for i in lines.size():
		if lines[i].begins_with("[gd_resource"):
			lines[i] = '[gd_resource type="Resource" format=3]'
		elif lines[i].begins_with("[ext_resource") and lines[i].contains("movement_profile.gd"):
			lines[i] = '[ext_resource type="Script" path="%s/movement_profile.gd" id="1_profile"]' % folder
	_write("%s/frigate.tres" % folder, "\n".join(lines))
	return ResourceLoader.load("%s/frigate.tres" % folder, "", ResourceLoader.CACHE_MODE_IGNORE)


## Writes the commit's MovementProfile script (without its class name) under user:// and returns its folder ("" on
## failure).
static func _prepare_profile_script(commit: String) -> String:
	var folder := "user://baseline_%s" % commit
	var path := "%s/movement_profile.gd" % folder
	if FileAccess.file_exists(path):
		return folder
	var source := _git_show(commit, "Movement/movement_profile.gd")
	if source == "":
		return ""
	DirAccess.make_dir_recursive_absolute(folder)
	_write(path, source.replace("class_name MovementProfile", ""))
	return folder


static func _git_show(commit: String, path: String) -> String:
	var output := []
	if OS.execute("git", ["show", "%s:%s" % [commit, path]], output, true) != 0:
		return ""
	return output[0]


static func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
