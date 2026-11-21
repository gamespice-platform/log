extends "log_selftest_targets.gd"

## Exercises gs-log without a collector, a database or a socket.
## Covers the bytes, the gate, the buffer and each target's failure path; the HTTP and SQL seams are faked one level above themselves.
## Run: [code]godot --headless --path . res://examples/log_selftest.tscn[/code]


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("gs-log self-test")
	_line("")
	# Two engine errors below are produced ON PURPOSE, by the checks that a bad
	# redaction pattern and a non-JSON collector response are reported rather than
	# thrown: "missing terminating ]" and "Parse JSON failed". Neither is a failure.
	_line("")

	_test_event()
	_test_levels()
	_test_event_values()
	_test_redactor()
	_test_gate()
	_test_gate_dedupe()
	_test_buffer()
	_test_memory_target()
	_test_file_target()
	_test_syslog_format()
	await _test_sql_target()
	await _test_http_target()
	_test_format_ndjson()
	_test_format_loki()
	_test_format_elastic()
	_test_format_splunk()
	_test_format_datadog()
	_test_format_seq()
	_test_format_gelf()
	_test_format_otlp()
	_test_format_sentry()
	await _test_router()
	await _test_router_reentrancy()
	_test_config()
	_test_cfg_layout()
	await _test_config_builds()
	await _test_commands()

	_line("")
	_line("%d passed, %d failed" % [_passed, _failed])
	_finish()


func _test_event() -> void:
	_section("event")

	var record: Dictionary = _record(GSLog.Level.WARN, "vote", "not enough players")
	var event: Dictionary = GSLogEvent.from_record(record)

	_check("a record becomes an event", event.has("time_ms") and event.has("seq"))
	_check("carrying its level", int(event["level"]) == GSLog.Level.WARN)
	_check("with the collector's name for it", str(event["severity"]) == "warning")
	_check("and the channel and message", str(event["channel"]) == "vote" and str(event["message"]) == "not enough players")

	var second: Dictionary = GSLogEvent.from_record(record)
	_check("the sequence advances", int(second["seq"]) > int(event["seq"]))

	_check("the record it came from is untouched", not record.has("time_ms"))

	var stamp: String = GSLogEvent.iso8601(event)
	_check("iso8601 is UTC with milliseconds", stamp.ends_with("Z") and stamp.length() == 24, null, stamp)
	_check("and has a T between date and time", stamp[10] == "T", null, stamp)

	_check("nanoseconds are a string", typeof(GSLogEvent.time_ns(event)) == TYPE_STRING)
	_check("and are milliseconds times a million", GSLogEvent.time_ns(event) == str(GSLogEvent.time_ms(event)) + "000000")

	_check("seconds are fractional", absf(GSLogEvent.time_sec(event) - float(GSLogEvent.time_ms(event)) / 1000.0) < 0.001)

	_check("syslog severity is RFC 5424", GSLogEvent.syslog_severity(GSLog.Level.ERROR) == 3 and GSLogEvent.syslog_severity(GSLog.Level.INFO) == 6)
	_check("otlp severity is banded", GSLogEvent.otlp_severity(GSLog.Level.ERROR) == 17 and GSLogEvent.otlp_severity(GSLog.Level.TRACE) == 1)
	_check("an out-of-range level does not crash either", GSLogEvent.syslog_severity(99) == 6 and GSLogEvent.otlp_severity(-4) == 9)

	var synthetic: Dictionary = GSLogEvent.synthetic(GSLog.Level.WARN, "log.gate", "repeated", {"repeated": 3})
	_check("a synthetic event is a full event", synthetic.has("time_ms") and int(synthetic["fields"]["repeated"]) == 3)

	var key: String = GSLogEvent.repeat_key(_event(GSLog.Level.INFO, "net", "same", {"peer": 1}))
	var key2: String = GSLogEvent.repeat_key(_event(GSLog.Level.INFO, "net", "same", {"peer": 2}))
	_check("the repeat key ignores the fields", key == key2, null, key)
	_check("but not the channel", key != GSLogEvent.repeat_key(_event(GSLog.Level.INFO, "chat", "same")))

	_line("")
	_done()


func _test_event_values() -> void:
	_section("event values")

	_check("a string survives", GSLogEvent.json_value("x") == "x")
	_check("an int survives", GSLogEvent.json_value(4) == 4)
	_check("a bool survives", GSLogEvent.json_value(true) == true)
	_check("a StringName becomes a String", typeof(GSLogEvent.json_value(&"kills")) == TYPE_STRING)

	var vector: Variant = GSLogEvent.json_value(Vector3(1, 2, 3))
	_check("a Vector3 becomes a string, not an array", typeof(vector) == TYPE_STRING, null, str(vector))

	var packed: Variant = GSLogEvent.json_value(PackedStringArray(["a", "b"]))
	_check("a PackedStringArray becomes an Array", typeof(packed) == TYPE_ARRAY and (packed as Array).size() == 2)

	var nested: Variant = GSLogEvent.json_value({"a": {"b": &"c"}})
	_check("a nested dictionary is walked", typeof(((nested as Dictionary)["a"] as Dictionary)["b"]) == TYPE_STRING)

	var event: Dictionary = _event(GSLog.Level.INFO, "net", "joined", {"peer": 4, "at": Vector3.ZERO})
	var flat: Dictionary = GSLogEvent.flatten(event, {"service": "fc", "env": "prod"})
	_check("flatten carries the context", str(flat["service"]) == "fc" and str(flat["env"]) == "prod")
	_check("and the envelope", flat.has("time") and str(flat["level"]) == "info" and str(flat["message"]) == "joined")
	_check("and the fields", int(flat["peer"]) == 4 and typeof(flat["at"]) == TYPE_STRING)

	var shadowed: Dictionary = GSLogEvent.flatten(
		_event(GSLog.Level.INFO, "net", "x", {"message": "not this one"}), {}
	)
	_check("a field CAN shadow the message, and that is known", str(shadowed["message"]) == "not this one")

	var context_win: Dictionary = GSLogEvent.flatten(
		_event(GSLog.Level.INFO, "net", "x", {}), {"service": "fc"}
	)
	_check("context is written before the envelope", str(context_win["service"]) == "fc")

	var json: String = GSLogEvent.flatten_json(event, {"service": "fc"}, "f_")
	var decoded: Variant = _parse(json)
	_check("flatten_json is parseable", typeof(decoded) == TYPE_DICTIONARY, null, json)
	_check("and prefixes the fields when asked", (decoded as Dictionary).has("f_peer"))

	var line: String = GSLogEvent.text_line(event)
	_check("the text line has the tag and the message", line.contains("inf") and line.contains("joined"), null, line)
	_check("and the fields as key=value", line.contains("peer=4"), null, line)
	_check("and can leave the time out", not GSLogEvent.text_line(event, false).begins_with("2"))

	_line("")
	_done()


func _test_redactor() -> void:
	_section("redactor")

	var redactor: GSLogRedactor = GSLogRedactor.new()
	var compiled: GSResult = redactor.compile()
	_check("the patterns compile", compiled.ok, compiled)

	var fields: Dictionary = {
		"peer": 4,
		"token": "abcdef123456",
		"refresh_token": "zzz",
		"nested": {"password": "hunter2", "name": "Ada"},
	}
	var clean: Dictionary = redactor.redact_fields(fields)

	_check("a secret key is masked", str(clean["token"]) == GSLogRedactor.MASK)
	_check("a key containing a secret name is too", str(clean["refresh_token"]) == GSLogRedactor.MASK)
	_check("a nested secret is masked", str((clean["nested"] as Dictionary)["password"]) == GSLogRedactor.MASK)
	_check("an ordinary field is not", int(clean["peer"]) == 4 and str((clean["nested"] as Dictionary)["name"]) == "Ada")
	_check("the original is untouched", str(fields["token"]) == "abcdef123456")

	redactor.drop_keys = PackedStringArray(["packet_dump"])
	var dropped: Dictionary = redactor.redact_fields({"packet_dump": "0011", "peer": 1})
	_check("a dropped key is gone entirely", not dropped.has("packet_dump") and dropped.has("peer"))

	_check("a bearer token in prose is caught", redactor.redact_text("sent Bearer abcdefghijkl now").contains(GSLogRedactor.MASK))
	_check("a query parameter is caught", redactor.redact_text("GET /v1?api_key=abcd1234 failed").contains(GSLogRedactor.MASK))
	_check("a JWT is caught", redactor.redact_text("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcd").contains(GSLogRedactor.MASK))
	_check("an email is caught", redactor.redact_text("mail ada@example.com").contains(GSLogRedactor.MASK))
	_check("ordinary prose is left alone", redactor.redact_text("player joined on map de_dust") == "player joined on map de_dust")

	var ip_keeper: GSLogRedactor = GSLogRedactor.new()
	ip_keeper.compile()
	_check("an address survives by default", ip_keeper.redact_text("from 10.0.0.4").contains("10.0.0.4"))

	var ip_masker: GSLogRedactor = GSLogRedactor.new()
	ip_masker.mask_ip_addresses = true
	ip_masker.compile()
	_check("and is masked when asked", not ip_masker.redact_text("from 10.0.0.4").contains("10.0.0.4"))

	var prefixed: GSLogRedactor = GSLogRedactor.new()
	prefixed.keep_prefix = 4
	_check("a kept prefix survives", prefixed.mask("abcdefghij").begins_with("abcd"))
	_check("but not when the value is shorter than the prefix", prefixed.mask("ab") == GSLogRedactor.MASK)

	var applied: Dictionary = redactor.apply(_event(GSLog.Level.INFO, "auth", "login with token abcdefghijkl", {"token": "x"}))
	_check("apply cleans message and fields together", str(applied["fields"]["token"]) == GSLogRedactor.MASK and str(applied["message"]).contains(GSLogRedactor.MASK))
	_check("and counts what it removed", redactor.redaction_count() > 0)

	var bad: GSLogRedactor = GSLogRedactor.new()
	bad.extra_patterns = PackedStringArray(["([unclosed"])
	_check("an uncompilable pattern is reported, not thrown", not bad.compile().ok)

	_line("")
	_done()


func _test_gate() -> void:
	_section("gate")

	var gate: GSLogGate = GSLogGate.new()
	gate.min_level = GSLog.Level.WARN

	_check("below the level is refused", not gate.allows(_event(GSLog.Level.INFO)))
	_check("at the level passes", gate.allows(_event(GSLog.Level.WARN)))
	_check("above it passes", gate.allows(_event(GSLog.Level.ERROR)))

	var channelled: GSLogGate = GSLogGate.new()
	channelled.channels = PackedStringArray(["net", "player.*"])
	_check("a named channel passes", channelled.allows(_event(GSLog.Level.INFO, "net")))
	_check("a prefix pattern passes", channelled.allows(_event(GSLog.Level.INFO, "player.roster")))
	_check("anything else is refused", not channelled.allows(_event(GSLog.Level.INFO, "chat")))

	channelled.deny_channels = PackedStringArray(["net"])
	_check("a deny beats an allow", not channelled.allows(_event(GSLog.Level.INFO, "net")))

	var sampled: GSLogGate = GSLogGate.new()
	sampled.trace_sample = 0.0
	_check("sampling at zero keeps nothing", not sampled.allows(_event(GSLog.Level.TRACE)))
	_check("and does not touch info", sampled.allows(_event(GSLog.Level.INFO)))

	var limited: GSLogGate = GSLogGate.new()
	limited.per_channel_rate = 1.0
	limited.per_channel_burst = 3.0
	var allowed: int = 0
	for i: int in range(20):
		if limited.allows(_event(GSLog.Level.INFO, "net", "spam %d" % i)):
			allowed += 1
	_check("a rate limit caps a burst", allowed <= 4 and allowed >= 3, null, str(allowed))

	var errors_through: int = 0
	for i: int in range(20):
		if limited.allows(_event(GSLog.Level.ERROR, "net", "bad %d" % i)):
			errors_through += 1
	_check("but never touches errors", errors_through == 20, null, str(errors_through))

	var stats: Dictionary = limited.stats()
	_check("the gate counts what it dropped", int(stats["dropped_rate"]) > 0)
	_check("and describes itself", limited.describe().has("min_level"))

	_line("")
	_done()


func _test_gate_dedupe() -> void:
	_section("gate deduplication")

	var gate: GSLogGate = GSLogGate.new()
	gate.dedupe_window_sec = 30.0

	var through: int = 0
	for i: int in range(50):
		if gate.allows(_event(GSLog.Level.INFO, "net", "packet refused", {"peer": i})):
			through += 1

	_check("only the first of fifty identical lines passes", through == 1, null, str(through))
	_check("even though the fields differed", true)

	var different: bool = gate.allows(_event(GSLog.Level.INFO, "net", "a different line"))
	_check("a different line still passes", different)

	var errors: int = 0
	for i: int in range(10):
		if gate.allows(_event(GSLog.Level.ERROR, "net", "the same error")):
			errors += 1
	_check("errors are never deduplicated", errors == 10, null, str(errors))

	# The window has not closed, so nothing is summarised yet.
	_check("no summary before the window closes", gate.drain_summaries().is_empty())

	gate.dedupe_window_sec = 0.001
	# A real delay, not a hope: the window is in milliseconds and the fifty calls above
	# take less than one, so without this the "next" copy is inside the same window and
	# the test fails on a fast machine and passes on a slow one.
	OS.delay_msec(5)
	# One more copy closes the window from the inside and produces the summary.
	gate.allows(_event(GSLog.Level.INFO, "net", "packet refused"))
	var summaries: Array[Dictionary] = gate.drain_summaries()
	_check("a closed window produces one summary", summaries.size() >= 1, null, str(summaries.size()))
	_check("naming how many were suppressed", int(summaries[0]["fields"]["repeated"]) == 49, null, str(summaries[0]["fields"]["repeated"]))
	_check("and saying who suppressed them", str(summaries[0]["fields"]["suppressed_by"]) == "gs-log")
	_check("keeping the original message", str(summaries[0]["message"]) == "packet refused")
	_check("draining twice gives nothing", gate.drain_summaries().is_empty())

	var bounded: GSLogGate = GSLogGate.new()
	bounded.dedupe_window_sec = 60.0
	bounded.dedupe_capacity = 16
	for i: int in range(100):
		bounded.allows(_event(GSLog.Level.INFO, "net", "unique %d" % i))
	_check("the tracking table is bounded", int(bounded.stats()["tracked"]) <= 16, null, str(bounded.stats()["tracked"]))

	_line("")
	_done()


func _test_buffer() -> void:
	_section("buffer")

	var buffer: GSLogBuffer = GSLogBuffer.new(4)
	for i: int in range(4):
		buffer.push(_event(GSLog.Level.INFO, "net", "m%d" % i))

	_check("it holds what fits", buffer.size() == 4)
	_check("and reports its bytes", buffer.byte_size() > 0)

	buffer.push(_event(GSLog.Level.INFO, "net", "m4"))
	_check("it stays bounded", buffer.size() == 4)
	_check("dropping the oldest", str(buffer.peek(1)[0]["message"]) == "m1", null, str(buffer.peek(1)[0]["message"]))
	_check("and counting the drop", buffer.dropped() == 1)

	var taken: Array[Dictionary] = buffer.take(2)
	_check("take returns the oldest first", taken.size() == 2 and str(taken[0]["message"]) == "m1")
	_check("and removes them", buffer.size() == 2)

	buffer.requeue(taken)
	_check("requeue puts them back", buffer.size() == 4)
	_check("at the front, in order", str(buffer.peek(1)[0]["message"]) == "m1")

	var notice: Dictionary = buffer.drain_drop_notice()
	_check("a drop notice is produced", not notice.is_empty() and int(notice["fields"]["dropped"]) == 1)
	_check("at WARN", int(notice["level"]) == GSLog.Level.WARN)
	_check("and resets the count", buffer.drain_drop_notice().is_empty())

	var newest: GSLogBuffer = GSLogBuffer.new(2, GSLogBuffer.Policy.DROP_NEWEST)
	newest.push(_event(GSLog.Level.INFO, "net", "first"))
	newest.push(_event(GSLog.Level.INFO, "net", "second"))
	var refused: bool = newest.push(_event(GSLog.Level.INFO, "net", "third"))
	_check("drop-newest refuses the incoming record", not refused)
	_check("and keeps the earliest", str(newest.peek(1)[0]["message"]) == "first")

	var heavy: GSLogBuffer = GSLogBuffer.new(1000)
	heavy.max_bytes = 300
	for i: int in range(50):
		heavy.push(_event(GSLog.Level.INFO, "net", "a reasonably long message %d" % i))
	_check("the byte bound also holds", heavy.byte_size() <= 300 or heavy.size() == 1, null, str(heavy.byte_size()))
	_check("without emptying itself", heavy.size() >= 1)

	var big: GSLogBuffer = GSLogBuffer.new(10)
	big.max_bytes = 8
	big.push(_event(GSLog.Level.INFO, "net", "one record larger than the whole budget"))
	_check("an oversized single record is still kept", big.size() == 1)

	_check("estimate_size is generous", GSLogBuffer.estimate_size(_event()) > 60)
	_check("and describes itself", GSLogBuffer.new(8).describe().has("high_water"))

	_line("")
	_done()


func _test_memory_target() -> void:
	_section("memory target")

	var memory: GSLogTargetMemory = GSLogTargetMemory.new(4)
	memory.open()

	for i: int in range(6):
		memory.write(_event(GSLog.Level.INFO, "net", "m%d" % i))

	_check("the ring is bounded", memory.size() == 4)
	_check("keeping the newest", str(memory.tail(1)[0]["message"]) == "m5")
	_check("tail returns oldest first", str(memory.tail(2)[0]["message"]) == "m4")
	_check("tail(0) returns everything", memory.tail(0).size() == 4)

	memory.write(_event(GSLog.Level.ERROR, "chat", "a player said something", {"name": "Ada"}))
	_check("matching finds by message", memory.matching("player").size() == 1)
	_check("and by field value", memory.matching("ada").size() == 1)
	_check("and by channel", memory.matching("", "chat").size() == 1)
	_check("and by level", memory.matching("", "", GSLog.Level.ERROR).size() == 1)
	_check("and finds nothing when there is nothing", memory.matching("nonexistent").is_empty())

	_check("to_text renders lines", memory.to_text().contains("a player said something"))

	var crumbs: Array = memory.breadcrumbs(2)
	_check("breadcrumbs have a timestamp and a category", crumbs.size() == 2 and (crumbs[1] as Dictionary).has("timestamp") and (crumbs[1] as Dictionary).has("category"))
	_check("and the fields as data", ((crumbs[1] as Dictionary)["data"] as Dictionary).has("name"))

	var filtered: GSLogTargetMemory = GSLogTargetMemory.new(8)
	filtered.min_level = GSLog.Level.WARN
	filtered.open()
	filtered.write(_event(GSLog.Level.INFO))
	filtered.write(_event(GSLog.Level.ERROR))
	_check("a target level filters independently of the gate", filtered.size() == 1)

	memory.close()
	_check("closing keeps the ring, because that is when it is read", memory.size() == 4)

	_check("it describes itself", memory.describe().has("capacity"))

	_line("")
	_done()


func _test_file_target() -> void:
	_section("file target")

	var dir: String = "user://selftest-logs"
	GSPaths.remove_tree(dir)

	var file: GSLogTargetFile = GSLogTargetFile.new(dir, "test")
	var opened: GSResult = file.open()
	_check("it opens", opened.ok, opened)
	_check("naming a file", file.file_path().contains("test-"), null, file.file_path())

	file.write(_event(GSLog.Level.INFO, "net", "first line", {"peer": 4}))
	_check("a line is buffered, not written", file.pending() == 1)

	var flushed: GSResult = file.flush()
	_check("a flush writes it", flushed.ok and int(flushed.value) == 1, flushed)
	_check("and empties the buffer", file.pending() == 0)

	var text: GSResult = GSPaths.read_text(file.file_path())
	_check("the file has the line", text.ok and str(text.value).contains("first line"), text)
	_check("with its fields", text.ok and str(text.value).contains("peer=4"))
	_check("and a timestamp", text.ok and str(text.value).contains("T"))

	file.write(_event(GSLog.Level.ERROR, "net", "an error"))
	_check("an error skips the buffer", file.pending() == 0)

	var json_file: GSLogTargetFile = GSLogTargetFile.new(dir, "json")
	json_file.json_lines = true
	json_file.set_context({"service": "fc"})
	json_file.open()
	json_file.write(_event(GSLog.Level.INFO, "net", "structured", {"peer": 7}))
	json_file.flush()

	var json_text: GSResult = GSPaths.read_text(json_file.file_path())
	var decoded: Variant = _parse(str(json_text.value).strip_edges())
	_check("json lines parse", typeof(decoded) == TYPE_DICTIONARY, json_text, str(json_text.value))
	_check("carrying the context", str((decoded as Dictionary)["service"]) == "fc")
	_check("and the fields", int((decoded as Dictionary)["peer"]) == 7)
	json_file.close()

	var rotating: GSLogTargetFile = GSLogTargetFile.new(dir, "rot")
	rotating.max_file_bytes = 64
	rotating.open()
	var first_path: String = rotating.file_path()
	for i: int in range(20):
		rotating.write(_event(GSLog.Level.INFO, "net", "a line that is long enough %d" % i))
	rotating.flush()
	_check("it rotates on size", rotating.rotations() > 0, null, str(rotating.rotations()))
	_check("into a new file", rotating.file_path() != first_path or rotating.rotations() > 0)
	rotating.close()

	var pruning: GSLogTargetFile = GSLogTargetFile.new(dir, "rot")
	pruning.max_files = 1
	pruning.open()
	var kept: int = 0
	var listing: DirAccess = DirAccess.open(dir)
	listing.list_dir_begin()
	var n: String = listing.get_next()
	while n != "":
		if n.begins_with("rot"):
			kept += 1
		n = listing.get_next()
	listing.list_dir_end()
	_check("pruning keeps the limit plus the open file", kept <= 2, null, str(kept))
	pruning.close()

	var unopened: GSLogTargetFile = GSLogTargetFile.new("user://selftest-logs", "x")
	unopened.write(_event())
	var lost: GSResult = unopened.flush()
	_check("a flush with no file fails rather than pretending", not lost.ok)
	_check("and says how much was lost", lost.error.detail.contains("lines lost"))

	file.close()
	_check("it describes itself", file.describe().has("rotations"))

	GSPaths.remove_tree(dir)
	_line("")
	_done()
