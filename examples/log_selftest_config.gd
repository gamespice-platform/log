extends "log_selftest_formats.gd"

## The config, layout, config-built targets, level and command checks.

func _test_config() -> void:
	_section("config")

	var config: GSLogConfig = GSLogConfig.new()
	_check("the defaults validate", config.validate().ok)
	_check("info is the default level", GSLogConfig.parse_level(config.level) == GSLog.Level.INFO)
	_check("error is the default mirror level", GSLogConfig.parse_level(config.mirror_min_level) == GSLog.Level.ERROR)

	_check("levels parse by name", GSLogConfig.parse_level("warn") == GSLog.Level.WARN)
	_check("and by the long spelling", GSLogConfig.parse_level("warning") == GSLog.Level.WARN)
	_check("and case-insensitively", GSLogConfig.parse_level("ERROR") == GSLog.Level.ERROR)
	_check("an unknown level is -1", GSLogConfig.parse_level("loud") == -1)

	config.level = "loud"
	_check("and fails validation", not config.validate().ok)
	config.level = "debug"

	config.channel_levels = PackedStringArray(["net=trace", "chat"])
	_check("a malformed channel level is refused", not config.validate().ok)
	config.channel_levels = PackedStringArray(["net=trace"])
	_check("a good one is accepted", config.validate().ok)

	config.remote_enabled = true
	config.remote_url = ""
	_check("remote logging with no URL is refused", not config.validate().ok)
	config.remote_format = "sentry"
	_check("and sentry with no DSN is too", not config.validate().ok)
	config.sentry_dsn = "https://k@h/1"
	_check("a DSN is enough for sentry", config.validate().ok)
	config.remote_format = "nonsense"
	config.remote_url = "https://x.example"
	_check("an unknown format is refused", not config.validate().ok)
	config.remote_enabled = false
	config.remote_format = "ndjson"

	config.sql_enabled = true
	config.sql_dialect = "oracle"
	_check("an unknown dialect is refused", not config.validate().ok)
	config.sql_dialect = "postgres"
	_check("a known one is not", config.validate().ok)
	_check("and maps to the schema's enum", GSLogConfig.dialect_of("postgres") == GSLogSqlSchema.Dialect.POSTGRES)
	config.sql_enabled = false

	_check("the secrets are named", config.sensitive_keys().has("remote_token") and config.sensitive_keys().has("sentry_dsn"))
	_check("the env prefix is the family's shape", config.env_prefix() == "GS_LOG_")
	_check("and so is the cli prefix", config.cli_prefix() == "--log-")

	var applied: PackedStringArray = config.apply_dictionary({
		"level": "warn", "file_basename": "fc", "memory_capacity": 64,
	})
	_check("a dictionary layer applies", config.level == "warn" and config.file_basename == "fc" and applied.size() == 3)
	_check("and an unknown key is remembered, not fatal", config.apply_dictionary({"nonsense": 1}).size() == 0 and config.unknown_keys.size() > 0)

	config.service = "fc"
	config.env = "prod"
	var tags: Dictionary = config.context_tags()
	_check("context tags skip what is empty", not tags.has("instance"))
	_check("and always name a host", tags.has("host"))

	config.remote_tags = PackedStringArray(["region=eu", "tier=free"])
	config.remote_token = "t"
	var loki: GSLogFormat = config.make_format()
	config.remote_format = "loki"
	loki = config.make_format()
	_check("a format is built by name", loki != null and loki.format_name() == "loki")
	_check("carrying the token", loki.token == "t")
	_check("and the fixed tags", (loki as GSLogFormatLoki).static_labels.has("region"))
	config.remote_format = "otlp"
	_check("otlp takes the service name", (config.make_format() as GSLogFormatOtlp).service_name == "fc")
	config.remote_format = "elasticsearch"
	_check("an alias resolves", config.make_format().format_name() == "elasticsearch")
	config.remote_format = "nonsense"
	_check("and an unknown name is null", config.make_format() == null)

	_line("")
	_done()


func _test_cfg_layout() -> void:
	_section("log.yml: cfg/addons/gs_log wins over the flat file, cfg/server/addons/gs_log wins over both")

	var legacy := "user://gs_log_selftest_legacy"
	var addon_dir := "user://cfg/addons/gs_log"
	var server_dir := "user://cfg/server/addons/gs_log"
	GSPaths.remove_tree(addon_dir)
	GSPaths.remove_tree(server_dir)
	GSPaths.remove_tree(legacy)
	GSCfgLegacy.reset()

	_write_text(legacy.path_join("log.yml"), "level: debug\nservice: old\n")
	var config := GSLogConfig.new()
	var res := config.load_cfg("log.yml", legacy)
	_check("only the flat file: it is still read", res.ok and config.level == "debug", res)
	_check("and warned once", GSCfgLegacy.warned_count() == 1)
	GSLogConfig.new().load_cfg("log.yml", legacy)
	_check("a second load does not warn again", GSCfgLegacy.warned_count() == 1)

	_write_text(addon_dir.path_join("log.yml"), "level: warn\n")
	config = GSLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the new path wins over the flat file", res.ok and config.level == "warn", res)
	_check("and the two are never merged", config.service == "")

	_write_text(server_dir.path_join("log.yml"), "level: error\nremote_token: abc\n")
	config = GSLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the operator's server layer wins", res.ok and config.level == "error", res)
	_check("a secret in a file is read", config.remote_token == "abc")

	var game_dir := "user://cfg/game/mg-test/gs_log"
	var server_game_dir := "user://cfg/server/game/mg-test/gs_log"
	GSAddonConfig.game = "mg-test"
	_write_text(game_dir.path_join("log.yml"), "level: trace\n")
	config = GSLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the game tier sits between the addon's and the operator's", res.ok and config.level == "error", res)
	GSPaths.remove_tree(server_dir)
	config = GSLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("and wins over the addon's own", res.ok and config.level == "trace", res)
	_write_text(server_game_dir.path_join("log.yml"), "level: fatal\n")
	config = GSLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the operator's per-game tier wins over the game's", res.ok and config.level == "fatal", res)
	GSAddonConfig.game = ""
	GSPaths.remove_tree("user://cfg/game/mg-test")
	GSPaths.remove_tree("user://cfg/server/game/mg-test")

	GSPaths.remove_tree(addon_dir)
	GSPaths.remove_tree(server_dir)
	GSPaths.remove_tree(legacy)
	GSCfgLegacy.reset()
	_write_text("user://cfg/server/gs_log/log.yml", "level: info\n")
	config = GSLogConfig.new()
	res = config.load_cfg("log.yml", legacy)
	_check("the old cfg/server/gs_log/ still loads", res.ok and config.level == "info", res)
	_check("and warns once", GSCfgLegacy.warned_count() == 1)
	GSPaths.remove_tree("user://cfg/server/gs_log")
	GSPaths.remove_tree(server_dir)
	GSPaths.remove_tree(legacy)
	GSCfgLegacy.reset()
	_line("")
	_done()


func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_config_builds() -> void:
	_section("config builds a router")

	var config: GSLogConfig = GSLogConfig.new()
	config.service = "fc"
	config.env = "test"
	config.file_enabled = true
	config.file_directory = "user://selftest-config"
	config.memory_enabled = true
	config.dedupe_window_sec = 5.0
	config.mirror_min_level = "error"
	config.flush_interval_sec = 30.0

	var router: GSLogRouter = config.build_router()
	_check("a router is built", router != null)
	_check("with the file and the memory ring", router.targets.size() == 2)
	_check("a redactor", router.redactor != null)
	_check("and a gate, because dedupe was asked for", router.gate != null and router.gate.dedupe_window_sec == 5.0)
	_check("the context is set", str(router.context["service"]) == "fc")
	_check("and the interval", router.flush_interval_sec == 30.0)

	config.remote_enabled = true
	config.remote_format = "seq"
	config.remote_url = "https://seq.example"
	config.remote_level = "warn"
	var with_remote: GSLogRouter = config.build_router()
	_check("a remote target is added", with_remote.targets.size() == 3)
	var remote: GSLogTarget = with_remote.find_target("seq")
	_check("named after its format", remote != null)
	_check("gated at the configured level", remote.gate != null and remote.gate.min_level == GSLog.Level.WARN)

	config.remote_format = "sentry"
	config.sentry_dsn = "https://k@h.example/1"
	var with_tracker: GSLogRouter = config.build_router()
	var tracker: GSLogTargetHttp = with_tracker.find_target("sentry") as GSLogTargetHttp
	_check("an error tracker gets the memory ring for breadcrumbs", tracker != null and tracker.breadcrumb_source != null)

	# add_child is what starts it: build_router leaves autostart on, so a host that adds
	# it to the tree has a working logger without a second call.
	add_child(router)
	await get_tree().process_frame
	_check("the built router starts on being added to the tree", router.is_started())
	_check("and set GSLog's mirror level", GSLog.mirror_min_level == GSLog.Level.ERROR)

	config.apply_levels()
	_check("apply_levels sets the global level", GSLog.get_level() == GSLog.Level.INFO)

	await router.shutdown()
	router.queue_free()
	# free(), not queue_free(): neither of these was ever added to the tree, and the
	# suite quits before the next idle frame would have collected them.
	with_remote.free()
	with_tracker.free()
	GSPaths.remove_tree("user://selftest-config")
	GSLog.set_level(GSLog.Level.ERROR)
	_line("")
	_done()


func _test_levels() -> void:
	_section("levels")

	_check("there are six, and OFF", GSLog.Level.OFF == 6 and GSLog.LEVEL_NAMES.size() == 7)
	_check("in severity order", GSLog.Level.TRACE < GSLog.Level.DEBUG and GSLog.Level.DEBUG < GSLog.Level.INFO and GSLog.Level.INFO < GSLog.Level.WARN and GSLog.Level.WARN < GSLog.Level.ERROR and GSLog.Level.ERROR < GSLog.Level.FATAL)
	_check("each has a name", GSLog.level_name(GSLog.Level.FATAL) == "FATAL")
	_check("and a tag", GSLog.LEVEL_TAGS[GSLog.Level.FATAL] == "FTL")

	# The level is in the line, at a fixed width, in both styles.
	for level: int in range(GSLog.Level.TRACE, GSLog.Level.OFF):
		var line: String = GSLogEvent.text_line(_event(level, "net", "a message"), false)
		_check(
			"a %s line shows its level" % GSLog.LEVEL_NAMES[level],
			line.begins_with(GSLog.LEVEL_TAGS[level]),
			null,
			line
		)

	_check("every tag is three characters", GSLog.level_column(GSLog.Level.INFO).length() == 3 and GSLog.level_column(GSLog.Level.FATAL).length() == 3)

	GSLog.level_style = GSLog.LevelStyle.NAME
	var named: String = GSLogEvent.text_line(_event(GSLog.Level.WARN, "net", "x"), false)
	_check("the NAME style spells it out", named.begins_with("WARN"), null, named)
	_check("padded to the same width for every level", GSLog.level_column(GSLog.Level.INFO).length() == GSLog.level_column(GSLog.Level.WARN).length())
	GSLog.level_style = GSLog.LevelStyle.TAG
	_check("and the style goes back", GSLogEvent.text_line(_event(GSLog.Level.WARN, "net", "x"), false).begins_with("WRN"))

	# Every wire format carries the level, under whatever name that format uses.
	var event: Dictionary = _event(GSLog.Level.ERROR, "net", "broke")
	_check("flatten names it", str(GSLogEvent.flatten(event, {})["level"]) == "error")
	_check("severity_name is the collectors' spelling", GSLogEvent.severity_name(GSLog.Level.WARN) == "warning")

	var json: Dictionary = _parse(GSLog.format_json(_record(GSLog.Level.WARN, "net", "x")))
	_check("gs-core's JSON has the name", str(json["level"]) == "WARN")
	_check("and the number, because a string sorts wrong", int(json["severity"]) == GSLog.Level.WARN)

	# GSLog.at, for a level that is data rather than a call site.
	var ring: GSLogTargetMemory = GSLogTargetMemory.new(8)
	ring.open()
	var sink: Callable = func(rec: Dictionary) -> void: ring.write(GSLogEvent.from_record(rec))
	var saved_level: int = GSLog.get_level()
	GSLog.set_level(GSLog.Level.TRACE)
	GSLog.add_sink(sink)
	GSLog.at(GSLog.Level.WARN, "test", "at a chosen level")
	_check("GSLog.at emits at the level it was given", ring.size() == 1 and int(ring.tail(1)[0]["level"]) == GSLog.Level.WARN)
	GSLog.at(GSLog.Level.OFF, "test", "this must not be logged")
	_check("and refuses OFF, which is a threshold and not a severity", ring.size() == 1)
	GSLog.remove_sink(sink)
	GSLog.set_level(saved_level)

	_line("")
	_done()


func _test_commands() -> void:
	_section("log command")

	var router: GSLogRouter = GSLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var memory: GSLogTargetMemory = GSLogTargetMemory.new(64)
	router.targets.append(memory)
	add_child(router)
	await router.start()
	GSLog.set_level(GSLog.Level.TRACE)

	var commands: GSLogCommands = GSLogCommands.new(router)

	_check("it claims `log` and nothing else", commands.claims("log") and not commands.claims("logs"))
	_check("and names it", commands.names().has("log"))
	_check("and has help", commands.help_for("log").contains("tail"))

	GSLog.info("net", "a line to find")
	GSLog.warn("chat", "another line")

	var tail: GSResult = commands.execute("log tail 5")
	_check("tail returns lines", tail.ok and str(tail.value).contains("a line to find"), tail)
	_check("with their level shown", str(tail.value).contains("inf") and str(tail.value).contains("WRN"))

	var grep: GSResult = commands.execute("log grep another")
	_check("grep finds one", grep.ok and str(grep.value).contains("another line") and not str(grep.value).contains("a line to find"), grep)
	_check("and says so when it finds none", str(commands.execute("log grep zzzznope").value).contains("no match"))

	var levels: GSResult = commands.execute("log level")
	_check("level lists all six and what they mean", levels.ok and str(levels.value).contains("FATAL") and str(levels.value).contains("cannot continue"), levels)

	var set_level: GSResult = commands.execute("log level warn")
	_check("level sets it", set_level.ok and GSLog.get_level() == GSLog.Level.WARN, set_level)
	_check("an unknown level is refused", not commands.execute("log level loud").ok)
	commands.execute("log level trace")

	var channel: GSResult = commands.execute("log channel net debug")
	_check("channel sets one channel", channel.ok and GSLog.get_channel_level("net") == GSLog.Level.DEBUG, channel)
	commands.execute("log channel net default")
	_check("and clears it again", GSLog.get_channel_level("net") == GSLog.get_level())

	var targets: GSResult = commands.execute("log targets")
	_check("targets lists them with their health", targets.ok and str(targets.value).contains("memory") and str(targets.value).contains("written"), targets)

	var status: GSResult = commands.execute("log")
	_check("a bare `log` is the status", status.ok and str(status.value).contains("log router"))

	var before: int = memory.size()
	var test: GSResult = commands.execute("log test error a deliberate one")
	_check("test emits a record", test.ok and memory.size() == before + 1, test)
	_check("at the level asked for", int(memory.tail(1)[0]["level"]) == GSLog.Level.ERROR)
	_check("with the message", str(memory.tail(1)[0]["message"]) == "a deliberate one")
	_check("on its own channel, so it cannot be mistaken for a real one", str(memory.tail(1)[0]["channel"]) == GSLogCommands.CHANNEL)

	var fatal_test: GSResult = commands.execute("log test fatal pretend everything broke")
	_check("but FATAL is refused, because it promises a shutdown", not fatal_test.ok, null, fatal_test.code())
	_check("and says why", fatal_test.error.detail.contains("cannot continue"))

	var unknown: GSResult = commands.execute("log nonsense")
	_check("an unknown subcommand lists the real ones", not unknown.ok and unknown.error.detail.contains("tail"))

	var completions: PackedStringArray = commands.complete("log ")
	_check("completion offers the subcommands", completions.has("log tail"), null, ",".join(completions))
	var level_completions: PackedStringArray = commands.complete("log level w")
	_check("and the level names", level_completions.has("log level warn"), null, ",".join(level_completions))

	var detached: GSLogCommands = GSLogCommands.new(null)
	_check("with no router it says so rather than failing", detached.execute("log").ok and str(detached.execute("log").value).contains("nowhere else"))
	_check("and refuses what it cannot do", not detached.execute("log tail").ok)

	await router.shutdown()
	router.queue_free()
	GSLog.set_level(GSLog.Level.ERROR)
	_line("")
	_done()
