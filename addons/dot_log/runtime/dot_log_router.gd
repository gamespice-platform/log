@tool
class_name GSLogRouter
extends Node

## Attaches to [GSLog] once and fans every record out to the targets.
## The node a project places; not an autoload, since a server and a client in one process need two.
## Usage and the reentrancy guard are in docs/design.md; [member _dispatching] is checked first and records produced while dispatching are counted and dropped.

const CHANNEL := "log.router"

## Emitted for every record after the targets have taken it.
## For live UI (a console, an overlay) without a sink of its own; the payload is the enriched event.
signal routed(event: Dictionary)

## Emitted when a target's [method GSLogTarget.flush] fails, so a server can put its
## shipper's health somewhere an operator sees it.
signal target_failed(target_name: String, error: GSError)

@export_group("Lifecycle")

## Attach to [GSLog] on [method Node._ready].
## Off for a router assembled in code that adds its targets first; [method start] does it by hand.
@export var autostart: bool = true

## Flush every target the moment a record at this level arrives.
## FATAL promises a shutdown, so anything still buffered would never be written. The flush is started, not awaited, so a log call never blocks on the network ([method shutdown] waits).
## Set to [constant GSLog.Level.OFF] to disable.
@export var flush_at_level: GSLog.Level = GSLog.Level.FATAL

## Seconds between flushes.
## A compromise: shorter means more small requests and writes, longer loses more to a hard kill. See [member GSLogTargetHttp.send_immediately_above].
@export_range(0.1, 300.0, 0.1) var flush_interval_sec: float = 2.0

@export_group("Pipeline")

## Applied to every record before any target sees it. Null disables redaction.
## One in front of all targets: a secret kept from the collector must not reach the file, which gets attached to bug reports.
@export var redactor: GSLogRedactor = null

## Applied before the per-target gates. Null passes everything [GSLog] emitted.
@export var gate: GSLogGate = null

## The targets, in order. A target may be added and removed at runtime.
@export var targets: Array[GSLogTarget] = []

@export_group("GSLog")

## Set [member GSLog.print_to_stdout] on start. -1 leaves it alone.
## A server with a file target usually still wants stdout for its supervisor; a shipped client usually does not.
@export_enum("leave:-1", "off:0", "on:1") var stdout_on_start: int = -1

## Set [member GSLog.mirror_min_level] on start, or -1 to leave it.
## Mirroring uses push_warning/push_error, and a debug build appends a full backtrace to each. ERROR is right for a server; use WARN to hunt one warning.
@export_enum(
	"leave:-1", "trace:0", "debug:1", "info:2", "warn:3", "error:4", "fatal:5", "off:6"
) var mirror_min_level: int = -1

## Context tags attached to every shipped record: service, env, host, instance, version.
## Not in the human file format, but essential to a collector holding several servers' records.
var context: Dictionary = {}

var _sink: Callable
var _timer: Timer = null
var _http_nodes: Array[GSHttp] = []
var _started: bool = false
var _dispatching: bool = false

var _received: int = 0
var _routed: int = 0
var _gated: int = 0
var _reentrant: int = 0
var _flushes: int = 0
var _fatals: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if autostart:
		# Awaited: start() suspends while opening targets, and a coroutine called
		# without await returns null rather than its result — which would then be a
		# null dereference on the line below. See docs/gdscript-hazards.md.
		var res: GSResult = await start()
		if not res.ok:
			GSLog.result(CHANNEL, "starting the log router", res)


func _exit_tree() -> void:
	if _started:
		stop()


## Opens every target and attaches to [GSLog].
## A target that fails to open is disabled and reported; the rest carry on, since degraded logging beats a server that will not start.
func start() -> GSResult:
	if _started:
		return GSResult.fail(GSError.CODE_STATE, "The log router is already started.")

	if stdout_on_start >= 0:
		GSLog.print_to_stdout = stdout_on_start == 1
	if mirror_min_level >= 0:
		GSLog.mirror_min_level = mirror_min_level

	if redactor != null:
		var compiled: GSResult = redactor.compile()
		if not compiled.ok:
			GSLog.result(CHANNEL, "compiling redaction patterns", compiled)

	var failures: PackedStringArray = PackedStringArray()

	for target: GSLogTarget in targets:
		var opened: GSResult = await _open_target(target)
		if not opened.ok:
			failures.append("%s: %s" % [target.target_name, opened.error.message])

	_timer = Timer.new()
	_timer.name = "FlushTimer"
	_timer.wait_time = flush_interval_sec
	_timer.autostart = true
	_timer.timeout.connect(_on_flush_timer)
	add_child(_timer)

	_sink = _ingest
	GSLog.add_sink(_sink)
	_started = true

	GSLog.info(
		CHANNEL,
		"log router started",
		{"targets": targets.size(), "interval": flush_interval_sec}
	)

	if not failures.is_empty():
		return GSResult.fail(
			GSError.CODE_IO,
			"%d of %d log targets could not be opened." % [
				failures.size(), targets.size()
			],
			"; ".join(failures)
		)

	return GSResult.success(targets.size())


## Detaches from [GSLog] and closes every target, flushing what is buffered.
## Synchronous (it runs from _exit_tree, where awaiting a round trip is unreliable): an HTTP target loses what has not gone out. Use [method shutdown] to wait.
func stop() -> void:
	if _sink.is_valid():
		GSLog.remove_sink(_sink)

	if _timer != null and is_instance_valid(_timer):
		_timer.queue_free()
		_timer = null

	for target: GSLogTarget in targets:
		if not target.is_buffered():
			target.close()
			continue
		# Not awaited: see above. A target whose flush is a coroutine runs to its first
		# suspension and no further, which for a file target is the whole of it.
		target.flush()
		target.close()

	_started = false


## Flushes everything and then stops. The clean path out of a process.
## Usage: [code]await router.shutdown()[/code] before [code]get_tree().quit()[/code].
func shutdown() -> void:
	if not _started:
		return
	await flush_all()
	stop()


func is_started() -> bool:
	return _started


## Adds a target and opens it. Returns the open result.
func add_target(target: GSLogTarget) -> GSResult:
	if target == null:
		return GSResult.fail(GSError.CODE_INVALID, "A null log target.")

	targets.append(target)

	if not _started:
		return GSResult.success(target.target_name)

	return await _open_target(target)


## Removes a target, flushing and closing it first.
func remove_target(target: GSLogTarget) -> void:
	if not targets.has(target):
		return
	if target.is_buffered():
		await target.flush()
	target.close()
	targets.erase(target)


## The first target with this name, or null.
## The parameter is not called `name` because shadowing [Node]'s `name` quietly reads the node's own.
func find_target(wanted: String) -> GSLogTarget:
	for target: GSLogTarget in targets:
		if target.target_name == wanted:
			return target
	return null


func _open_target(target: GSLogTarget) -> GSResult:
	# Context is pushed rather than pulled so a target does not need a reference back to
	# the router — which would be a cycle between a Node and a Resource it holds.
	if target.has_method("set_context"):
		target.call("set_context", context)

	if target is GSLogTargetHttp:
		var http_target: GSLogTargetHttp = target as GSLogTargetHttp
		if http_target.http == null:
			http_target.http = _make_http()

	var opened: GSResult = await target.open()
	if opened == null:
		opened = GSResult.success(null)

	if not opened.ok:
		# Disabled rather than removed: the configuration is still visible in describe(),
		# which is how an operator finds out why nothing is arriving.
		target.enabled = false
		GSLog.warn(
			CHANNEL,
			"a log target could not be opened",
			{
				"target": target.target_name,
				"why": opened.error.message,
				"detail": opened.error.detail,
			}
		)

	return opened


func _make_http() -> GSHttp:
	var http: GSHttp = GSHttp.new()
	http.name = "LogHttp%d" % (_http_nodes.size() + 1)
	# The user agent is how a collector's operator identifies what is filling their
	# quota, which is a question they do ask.
	http.user_agent = "dot-log/0.1 (Godot)"
	add_child(http)
	_http_nodes.append(http)
	return http


## Replaces the context tags and pushes them to every target.
func set_context(new_context: Dictionary) -> void:
	context = new_context.duplicate()
	_push_context()


## Sets one tag. The common case at runtime is the map or the match id changing.
func set_tag(key: String, value: Variant) -> void:
	context[key] = value
	_push_context()


func _push_context() -> void:
	for target: GSLogTarget in targets:
		if target.has_method("set_context"):
			target.call("set_context", context)


## The sink [GSLog] calls. Never call this directly.
func _ingest(record: Dictionary) -> void:
	if _dispatching:
		# A target logged from inside write(). Counted and dropped: the alternative is
		# unbounded recursion, and a logger that can crash the process it is
		# instrumenting is worse than a logger that loses a line about itself.
		_reentrant += 1
		return

	_received += 1

	var event: Dictionary = GSLogEvent.from_record(record)

	if gate != null and not gate.allows(event):
		_gated += 1
		return

	if redactor != null:
		event = redactor.apply(event)

	_dispatch(event)


func _dispatch(event: Dictionary) -> void:
	_dispatching = true

	for target: GSLogTarget in targets:
		if target.accepts(event):
			target.write(event)

	_dispatching = false
	_routed += 1

	# Emitted outside the guard on purpose: a listener is entitled to log, and a
	# listener is not a target — it cannot re-enter a write that has already finished.
	routed.emit(event)

	if int(event.get("level", GSLog.Level.INFO)) >= flush_at_level:
		_fatals += 1
		flush_all()


## Injects an event that did not come through [GSLog].
## For dropped-record notices and repeat summaries, which are produced inside the dispatch the reentrancy guard protects.
func inject(event: Dictionary) -> void:
	if _dispatching:
		return
	_dispatch(event)


func _on_flush_timer() -> void:
	# Not awaited: a Timer's callback is not a coroutine and the flush may take longer
	# than the interval. The per-target `_sending` guards make an overlapping call a
	# no-op rather than a double send.
	flush_all()


## Flushes every buffered target, and emits the pipeline's own summaries first.
func flush_all() -> void:
	_flushes += 1

	if gate != null:
		for summary: Dictionary in gate.drain_summaries():
			_dispatch(summary)

	for target: GSLogTarget in targets:
		if not target.enabled or not target.is_buffered():
			continue

		var res: GSResult = await target.flush()
		if res != null and not res.ok:
			target_failed.emit(target.target_name, res.error)


func describe() -> Dictionary:
	return {
		"started": _started,
		"targets": targets.size(),
		"received": _received,
		"routed": _routed,
		"gated": _gated,
		"reentrant_dropped": _reentrant,
		"flushes": _flushes,
		"urgent_flushes": _fatals,
		"context": context,
	}


func describe_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	out.append("log router: %s, %d targets, %d records in, %d out" % [
		"started" if _started else "stopped", targets.size(), _received, _routed
	])

	if _reentrant > 0:
		out.append("  %d records dropped as reentrant (a target logged from write())"
			% _reentrant)

	if gate != null:
		out.append("  gate: " + str(gate.describe()))

	if redactor != null:
		out.append("  redactor: " + str(redactor.describe()))

	for target: GSLogTarget in targets:
		out.append("  target %s" % target.target_name)
		out.append_array(target.describe_lines())

	return out


## Whether every enabled target is currently working.
## The question a health endpoint asks: a shipper failing for an hour is worth knowing separately from the server being up.
func is_healthy() -> bool:
	for target: GSLogTarget in targets:
		if not target.enabled:
			continue
		if not target.is_open():
			return false
		if target is GSLogTargetHttp and (target as GSLogTargetHttp).circuit_open_sec() > 0.0:
			return false
	return true
