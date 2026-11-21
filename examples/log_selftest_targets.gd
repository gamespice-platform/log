extends "log_selftest_config.gd"

## The syslog, SQL and HTTP target checks and the router checks, with the fakes they stand on.


## A GSHttp that answers from a script instead of from the network.
## Extends the real class because GSLogTargetHttp's field is typed; a fake that cannot be assigned proves nothing.
class FakeHttp extends GSHttp:
	var requests: Array[Dictionary] = []
	var status: int = 200
	var body: String = "{}"
	var transport_error: bool = false

	func request(
		method: int,
		path: String,
		body_bytes: PackedByteArray = PackedByteArray(),
		headers: Dictionary = {},
		decode_text: bool = true
	) -> GSResult:
		requests.append({
			"method": method,
			"url": path,
			"body": body_bytes.get_string_from_utf8(),
			"headers": headers.duplicate(),
		})

		if transport_error:
			return GSResult.fail(GSError.CODE_NETWORK, "the collector is unreachable")

		if status < 200 or status >= 300:
			return GSResult.failure(GSError.from_http(status, body))

		return GSResult.success({
			"status": status,
			"headers": {},
			"body": body.to_utf8_buffer(),
			"body_text": body,
			"attempts": 1,
		})

	func last_body() -> String:
		return "" if requests.is_empty() else str(requests[requests.size() - 1]["body"])


## A SQL driver that records statements. The shape GameSpice Moderation's driver already has.
class FakeDriver extends RefCounted:
	var statements: Array[Dictionary] = []
	var fail_next: bool = false
	var rows: Array = []

	func driver_name() -> String:
		return "fake"

	func is_available() -> GSResult:
		return GSResult.success(null)

	func execute(sql: String, params: Array = []) -> GSResult:
		statements.append({"sql": sql, "params": params.duplicate()})
		if fail_next:
			fail_next = false
			return GSResult.fail(GSError.CODE_NETWORK, "the database went away")
		return GSResult.success(params.size())

	func query(sql: String, params: Array = []) -> GSResult:
		statements.append({"sql": sql, "params": params.duplicate()})
		return GSResult.success(rows)

	func inserts() -> Array:
		var out: Array = []
		for s: Dictionary in statements:
			if str(s["sql"]).begins_with("INSERT"):
				out.append(s)
		return out


func _test_syslog_format() -> void:
	_section("syslog")

	var syslog: GSLogTargetSyslog = GSLogTargetSyslog.new("127.0.0.1", 514)
	syslog.host_name = "eu-1"
	syslog.app_name = "fc"
	syslog.set_context({"service": "fc"})

	var message: String = syslog.format_message(
		_event(GSLog.Level.ERROR, "net", "peer refused", {"peer": 4})
	)

	# facility 16 * 8 + severity 3 = 131
	_check("the priority is facility and severity", message.begins_with("<131>1 "), null, message)
	_check("the version is 1", message.split(" ")[0].ends_with("1") or message.contains(">1 "))
	_check("the host and app are there", message.contains("eu-1") and message.contains("fc"), null, message)
	_check("the channel is the message id", message.contains(" net "), null, message)
	_check("the fields are structured data", message.contains("[dot@32473") and message.contains("peer=\"4\""), null, message)
	_check("the context is too", message.contains("service=\"fc\""))
	_check("and the message is last", message.ends_with("peer refused"), null, message)

	var warn: String = syslog.format_message(_event(GSLog.Level.WARN, "vote", "waiting"))
	_check("a warning is severity 4", warn.begins_with("<132>"), null, warn)

	syslog.structured_data = false
	_check("structured data can be turned off", syslog.format_message(_event()).contains(" - "))
	syslog.structured_data = true

	var awkward: String = syslog.format_message(
		_event(GSLog.Level.INFO, "chat", "said", {"text": "a \"quoted\" ] thing"})
	)
	_check("a quote in a value is escaped", awkward.contains("\\\""), null, awkward)
	_check("and so is a bracket", awkward.contains("\\]"), null, awkward)

	var spacey: String = syslog.format_message(
		_event(GSLog.Level.INFO, "chat", "said", {"a key": "v"})
	)
	_check("a space in a param name is replaced", spacey.contains("a_key="), null, spacey)

	syslog.max_message_bytes = 480
	var long_message: String = ""
	for i: int in range(200):
		long_message += "long "
	var truncated: String = syslog.format_message(_event(GSLog.Level.INFO, "net", long_message))
	_check("a long message is truncated to the byte limit", truncated.to_utf8_buffer().size() <= 480, null, str(truncated.to_utf8_buffer().size()))
	_check("and says so", truncated.ends_with("..."))

	var unicode: String = syslog.format_message(_event(GSLog.Level.INFO, "chat", "ünïcödé ".repeat(200)))
	_check("truncation counts bytes, not characters", unicode.to_utf8_buffer().size() <= 480, null, str(unicode.to_utf8_buffer().size()))

	_check("an empty host becomes the nil value", syslog.format_message(_event(GSLog.Level.INFO, "", "x")).contains(" - "))

	syslog.transport = GSLogTargetSyslog.Transport.TCP
	_check("tcp is buffered", syslog.is_buffered())
	syslog.transport = GSLogTargetSyslog.Transport.UDP
	_check("udp is not", not syslog.is_buffered())
	_check("it describes itself", syslog.describe().has("transport"))

	_line("")
	_done()


func _test_sql_target() -> void:
	_section("sql target")

	_check("the schema quotes an identifier", GSLogSqlSchema.quote_identifier("dot_log", GSLogSqlSchema.Dialect.SQLITE) == "\"dot_log\"")
	_check("and refuses one it cannot quote", not GSLogSqlSchema.quote_identifier("a\"b; DROP", GSLogSqlSchema.Dialect.SQLITE).contains("DROP;"))
	_check("mysql uses backticks", GSLogSqlSchema.quote_identifier("t", GSLogSqlSchema.Dialect.MYSQL) == "`t`")
	_check("postgres numbers its placeholders", GSLogSqlSchema.placeholder(3, GSLogSqlSchema.Dialect.POSTGRES) == "$3")
	_check("sqlite does not", GSLogSqlSchema.placeholder(3, GSLogSqlSchema.Dialect.SQLITE) == "?")

	var ddl: PackedStringArray = GSLogSqlSchema.create_statements("dot_log", GSLogSqlSchema.Dialect.SQLITE)
	_check("the DDL is a table and two indexes", ddl.size() == 3, null, str(ddl.size()))
	_check("and is idempotent", ddl[0].contains("IF NOT EXISTS"))

	var pg: PackedStringArray = GSLogSqlSchema.create_statements("dot_log", GSLogSqlSchema.Dialect.POSTGRES)
	_check("postgres gets a JSON column type", pg[0].contains("JSONB"))

	# The level is a sortable column, twice over: a number to order and compare by, and
	# a name to read. Sorting on the name alone gives ERROR < FATAL < INFO < WARN, which
	# is alphabetical and almost exactly the wrong order.
	_check("level is its own INTEGER column", ddl[0].contains("level INTEGER NOT NULL"), null, ddl[0])
	_check("with the name beside it", ddl[0].contains("level_name"))
	_check("and both are in the column list", GSLogSqlSchema.COLUMNS.has("level") and GSLogSqlSchema.COLUMNS.has("level_name"))
	_check("indexed with the channel, which is how it is queried", ddl[2].contains("(channel, level)"), null, ddl[2])

	var events: Array = [_event(GSLog.Level.WARN, "net", "one"), _event(GSLog.Level.INFO, "net", "two")]
	var insert: Dictionary = GSLogSqlSchema.insert_statement("dot_log", GSLogSqlSchema.Dialect.SQLITE, events, {"service": "fc"})
	_check("one statement covers the batch", str(insert["sql"]).begins_with("INSERT INTO") and str(insert["sql"]).count("(?") == 2)
	_check("with a parameter per column per row", (insert["params"] as Array).size() == GSLogSqlSchema.COLUMNS.size() * 2)
	_check("the message is a parameter, never inline", not str(insert["sql"]).contains("one"))
	var bound: Array = insert["params"]
	_check("the level binds as a number", typeof(bound[2]) == TYPE_INT and int(bound[2]) == GSLog.Level.WARN)
	_check("and its name beside it", str(bound[3]) == "WARN")
	_check("so ORDER BY level is severity order", int(bound[2]) > int(bound[2 + GSLogSqlSchema.COLUMNS.size()]), null, "WARN then INFO")
	_check("and the context is JSON", str((insert["params"] as Array)[7]).contains("fc"))

	var prune: Dictionary = GSLogSqlSchema.prune_statement("dot_log", GSLogSqlSchema.Dialect.SQLITE, 1000)
	_check("pruning is a parameterised delete", str(prune["sql"]).begins_with("DELETE FROM") and int((prune["params"] as Array)[0]) == 1000)

	var tail: Dictionary = GSLogSqlSchema.tail_statement("dot_log", GSLogSqlSchema.Dialect.SQLITE, 10, "net")
	_check("a tail filters and limits", str(tail["sql"]).contains("WHERE channel") and (tail["params"] as Array).size() == 2)

	var driver: FakeDriver = FakeDriver.new()
	var sql: GSLogTargetSql = GSLogTargetSql.new(driver, "dot_log")
	var opened: GSResult = await sql.open()
	_check("the target opens against a driver", opened.ok, opened)
	_check("creating the table", driver.statements.size() == 3)

	sql.write(_event(GSLog.Level.INFO, "net", "queued"))
	_check("a record is queued", sql.pending() == 1)

	var sent: GSResult = await sql.flush()
	_check("a flush inserts it", sent.ok and int(sent.value) == 1, sent)
	_check("with one INSERT", driver.inserts().size() == 1)
	_check("and empties the queue", sql.pending() == 0)

	driver.fail_next = true
	sql.write(_event(GSLog.Level.INFO, "net", "kept"))
	var failed: GSResult = await sql.flush()
	_check("a failed insert is reported", not failed.ok, null, failed.code())
	_check("and the record is kept", sql.pending() == 1)

	var retried: GSResult = await sql.flush()
	_check("the next flush sends it", retried.ok and sql.pending() == 0, retried)

	var pruned: GSResult = await sql.prune()
	_check("pruning runs a delete", pruned.ok and str(driver.statements[driver.statements.size() - 1]["sql"]).begins_with("DELETE"))

	var read: GSResult = await sql.tail(5)
	_check("a tail reads back", read.ok, read)

	var driverless: GSLogTargetSql = GSLogTargetSql.new(null, "x")
	var refused: GSResult = await driverless.open()
	_check("no driver is a clear failure, not a silent no-op", not refused.ok and refused.code() == GSError.CODE_STATE)

	_check("it describes itself", sql.describe().has("inserted"))

	_line("")
	_done()


func _test_http_target() -> void:
	_section("http target")

	var http: FakeHttp = FakeHttp.new()
	var format: GSLogFormatNdjson = GSLogFormatNdjson.new()
	var target: GSLogTargetHttp = GSLogTargetHttp.new(format, "https://logs.example")
	target.http = http

	var opened: GSResult = target.open()
	_check("it opens with a format and an endpoint", opened.ok, opened)
	_check("the endpoint is the base when the format has no path", target.resolved_endpoint() == "https://logs.example")

	target.write(_event(GSLog.Level.INFO, "net", "one"))
	target.write(_event(GSLog.Level.INFO, "net", "two"))
	_check("records are queued, not sent", http.requests.is_empty() and target.pending() == 2)

	var sent: GSResult = await target.flush()
	_check("a flush sends one request", sent.ok and http.requests.size() == 1, sent)
	_check("with both records", http.last_body().split("\n", false).size() == 2)
	_check("and empties the queue", target.pending() == 0)
	_check("as a POST", int(http.requests[0]["method"]) == HTTPClient.METHOD_POST)
	_check("with the format's content type", str((http.requests[0]["headers"] as Dictionary)["Content-Type"]) == "application/x-ndjson")

	http.status = 500
	target.write(_event(GSLog.Level.INFO, "net", "kept"))
	var failed: GSResult = await target.flush()
	_check("a 500 is reported", not failed.ok)
	_check("and the record is kept for the retry", target.pending() == 1)

	http.status = 400
	var rejected: GSResult = await target.flush()
	_check("a 400 is reported too", not rejected.ok)
	_check("but the record is dropped, because it can never be accepted", target.pending() == 0)

	http.status = 500
	for i: int in range(10):
		target.write(_event(GSLog.Level.INFO, "net", "m%d" % i))
		await target.flush()
	_check("repeated failures open the circuit", target.circuit_open_sec() > 0.0)

	var before: int = http.requests.size()
	await target.flush()
	_check("and an open circuit sends nothing", http.requests.size() == before)

	await _check_http_variants()

	_check("it describes itself", target.describe().has("circuit_open_for"))

	# GSHttp is a Node, and a Node nobody parented is a Node nobody frees. Left alone
	# these show up as "ObjectDB instances were leaked at exit", which is a real warning
	# about a real leak and must not be background noise in this suite's output.
	http.free()

	_line("")
	_done()


## Immediate sends, path joining and the targets that cannot open or accept.
func _check_http_variants() -> void:
	var urgent_http: FakeHttp = FakeHttp.new()
	var urgent: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatNdjson.new(), "https://logs.example")
	urgent.http = urgent_http
	urgent.send_immediately_above = GSLog.Level.ERROR
	urgent.open()
	urgent.write(_event(GSLog.Level.INFO))
	_check("an ordinary record does not ask for a flush", not urgent.wants_flush())
	urgent.write(_event(GSLog.Level.ERROR))
	_check("an error does", urgent.wants_flush())

	var pathed: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatLoki.new(), "https://loki.example")
	_check("a format's path is appended", pathed.resolved_endpoint() == "https://loki.example/loki/api/v1/push", null, pathed.resolved_endpoint())

	var gateway: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatLoki.new(), "https://gw.example/logs/push")
	_check("but not to a URL that already has a path", gateway.resolved_endpoint() == "https://gw.example/logs/push", null, gateway.resolved_endpoint())

	var no_endpoint_http: FakeHttp = FakeHttp.new()
	var no_endpoint: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatNdjson.new(), "")
	no_endpoint.http = no_endpoint_http
	_check("no endpoint is a clear failure", not no_endpoint.open().ok)

	var no_http: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatNdjson.new(), "https://x.example")
	_check("and so is no GSHttp node", not no_http.open().ok)

	var tracker: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatSentry.new(), "")
	_check("an error tracker with no gate takes WARN and above", tracker.accepts(_event(GSLog.Level.WARN)))
	_check("and nothing below it", not tracker.accepts(_event(GSLog.Level.INFO)))
	urgent_http.free()
	no_endpoint_http.free()


func _test_router() -> void:
	_section("router")

	var router: GSLogRouter = GSLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var memory: GSLogTargetMemory = GSLogTargetMemory.new(32)
	router.targets.append(memory)
	router.set_context({"service": "fc", "env": "test"})
	add_child(router)

	var started: GSResult = await router.start()
	_check("the router starts", started.ok, started)
	_check("and is attached", router.is_started())

	GSLog.set_level(GSLog.Level.TRACE)
	GSLog.info("net", "a routed line", {"peer": 4})
	_check("a GSLog call reaches the target", memory.size() == 1, null, str(memory.size()))

	var event: Dictionary = memory.tail(1)[0]
	_check("as an enriched event", event.has("time_ms") and event.has("seq"))
	_check("with the message intact", str(event["message"]) == "a routed line")

	var seen: Array = []
	router.routed.connect(func(e: Dictionary) -> void: seen.append(e))
	GSLog.info("net", "watched")
	_check("the routed signal fires", seen.size() == 1)

	router.redactor = GSLogRedactor.new()
	GSLog.info("auth", "signing in", {"token": "abcdef"})
	_check("the redactor runs before the targets", str(memory.tail(1)[0]["fields"]["token"]) == GSLogRedactor.MASK)

	router.gate = GSLogGate.new()
	router.gate.min_level = GSLog.Level.WARN
	var before: int = memory.size()
	GSLog.info("net", "below the router gate")
	_check("the router gate refuses a record", memory.size() == before)
	GSLog.warn("net", "above it")
	_check("and passes one above it", memory.size() == before + 1)
	router.gate = null

	router.set_tag("map", "de_dust")
	_check("a tag reaches the context", str(router.context["map"]) == "de_dust")

	await _check_router_targets(router)
	await _check_router_urgent_flush(router)

	_check("describe_lines says what is going on", ",".join(router.describe_lines()).contains("log router"))
	_check("and describe counts records", int(router.describe()["received"]) > 0)

	await router.shutdown()
	_check("shutdown detaches", not router.is_started())

	var after: int = memory.size()
	GSLog.info("net", "after shutdown")
	_check("and nothing arrives afterwards", memory.size() == after)

	router.queue_free()
	GSPaths.remove_tree("user://selftest-router")
	GSLog.set_level(GSLog.Level.ERROR)
	_line("")
	_done()

## Targets added and removed while the router runs.
func _check_router_targets(router: GSLogRouter) -> void:
	var file: GSLogTargetFile = GSLogTargetFile.new("user://selftest-router", "r")
	var added: GSResult = await router.add_target(file)
	_check("a target can be added at runtime", added.ok and router.targets.size() == 2, added)
	_check("and found by name", router.find_target("file") == file)

	GSLog.info("net", "to both")
	_check("a record reaches both", file.pending() == 1)

	await router.flush_all()
	_check("flush_all writes it", file.pending() == 0)

	await router.remove_target(file)
	_check("a target can be removed", router.targets.size() == 1)

	var broken: GSLogTargetSql = GSLogTargetSql.new(null, "x")
	await router.add_target(broken)
	_check("a target that cannot open is disabled, not fatal", not broken.enabled and router.is_started())


## A FATAL must not be sitting in a buffer when the process goes.
func _check_router_urgent_flush(router: GSLogRouter) -> void:
	var fatal_http: FakeHttp = FakeHttp.new()
	var shipper: GSLogTargetHttp = GSLogTargetHttp.new(GSLogFormatNdjson.new(), "https://logs.example")
	shipper.http = fatal_http
	await router.add_target(shipper)

	GSLog.info("net", "an ordinary record")
	_check("an ordinary record waits for the flush", shipper.pending() == 1 and fatal_http.requests.is_empty())

	GSLog.fatal("net", "the process cannot continue")
	_check("a FATAL flushes every target at once", fatal_http.requests.size() == 1, null, str(shipper.pending()))
	_check("carrying the record that said so", fatal_http.last_body().contains("cannot continue"))
	_check("and the router counts the urgent flush", int(router.describe()["urgent_flushes"]) == 1)
	await router.remove_target(shipper)
	fatal_http.free()



func _test_router_reentrancy() -> void:
	_section("router reentrancy")

	var router: GSLogRouter = GSLogRouter.new()
	router.autostart = false
	router.flush_interval_sec = 60.0
	var loud: LoudTarget = LoudTarget.new()
	router.targets.append(loud)
	add_child(router)
	await router.start()

	GSLog.set_level(GSLog.Level.TRACE)
	GSLog.info("net", "the line that makes the target log")

	_check("a target that logs does not recurse", loud.writes == 1, null, str(loud.writes))
	_check("and the reentrant record is counted", int(router.describe()["reentrant_dropped"]) >= 1)
	_check("the process is, notably, still alive", true)

	await router.shutdown()
	router.queue_free()
	GSLog.set_level(GSLog.Level.ERROR)
	_line("")
	_done()


## A target that does exactly the forbidden thing: logs from inside write().
class LoudTarget extends GSLogTarget:
	var writes: int = 0

	func _init() -> void:
		target_name = "loud"

	func write(event: Dictionary) -> void:
		writes += 1
		# The natural, wrong thing to write. Without the router's guard this is
		# unbounded recursion and the process dies here.
		GSLog.warn("loud", "I am writing a record")
