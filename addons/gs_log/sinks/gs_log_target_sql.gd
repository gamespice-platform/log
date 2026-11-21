@tool
class_name GSLogTargetSql
extends GSLogTarget

## Writes the log into a database table, in batches.
## Godot ships no database driver, so the driver is duck-typed ([code]execute(sql, params) -> GSResult[/code], the shape of GameSpice Moderation's [code]GSSqlDriver[/code]) and everything else is in [GSLogSqlSchema].
## Keep the file target on too: this one has a dependency, so it can be unavailable.

const SELF_CHANNEL := "log.sql"

## Table name. Quoted, and anything unquotable is replaced rather than escaped.
@export var table: String = "gs_log"

## Which SQL to speak. Ask the driver if it says, and set it here if it does not.
@export var dialect: GSLogSqlSchema.Dialect = GSLogSqlSchema.Dialect.SQLITE

## Records per INSERT.
## One statement per batch, so also the transaction size. Older SQLite caps at 999 parameters (124 rows of eight), so this is checked at send.
@export_range(1, 5000, 1) var batch_size: int = 100

## Records held while the database is unavailable.
@export_range(16, 200000, 16) var max_queued: int = 8192

## Delete rows older than this many days on [method prune]. 0 keeps everything.
## Never automatic: a DELETE over a large table does not belong in a mid-round flush. Call it from a scheduled task or console command.
@export_range(0, 3650, 1) var retention_days: int = 30

## The database driver. Any object with `execute(sql, params) -> GSResult`.
var driver: Object = null

var _buffer: GSLogBuffer = null
var _context: Dictionary = {}
var _sending: bool = false
var _inserted: int = 0


func _init(p_driver: Object = null, p_table: String = "") -> void:
	target_name = "sql"
	driver = p_driver
	if p_table != "":
		table = p_table
	_buffer = GSLogBuffer.new(max_queued, GSLogBuffer.Policy.DROP_OLDEST)


func set_context(context: Dictionary) -> void:
	_context = context


## Checks the driver and creates the table.
## Created here, not by a migration: a log table has no history worth migrating, so a changed shape starts a new table.
func open() -> GSResult:
	if driver == null:
		return GSResult.fail(
			GSError.CODE_STATE,
			"No database driver was given to the SQL log target.",
			"assign `driver` before starting the router"
		)

	if not driver.has_method("execute"):
		return GSResult.fail(
			GSError.CODE_INVALID,
			"The log driver has no execute(sql, params) method.",
			str(driver.get_class())
		)

	if driver.has_method("is_available"):
		var available: GSResult = driver.is_available()
		if available != null and not available.ok:
			return available

	if driver.has_method("is_open") and not driver.is_open():
		if driver.has_method("open"):
			var opened: GSResult = await driver.open()
			if opened != null and not opened.ok:
				return opened.wrap("opening the log database")

	_buffer.max_records = max_queued

	for sql: String in GSLogSqlSchema.create_statements(table, dialect):
		var made: GSResult = await driver.execute(sql, [])
		if made != null and not made.ok:
			return made.wrap("creating the log table")

	_opened = true
	return GSResult.success(table)


func close() -> void:
	_opened = false
	# The driver is not closed here: it was given to us and may well be the same
	# connection something else is using. Whoever opened it closes it.


func write(event: Dictionary) -> void:
	super(event)
	_buffer.push(event)


func flush() -> GSResult:
	if _buffer.is_empty() or not _opened:
		return GSResult.success(0)

	if _sending:
		# One batch in flight at a time. Two concurrent inserts from one queue would
		# interleave, and a retry would then have to work out which rows had landed.
		return GSResult.success(0)

	_sending = true
	var total: int = 0

	while not _buffer.is_empty():
		var batch: Array[Dictionary] = _buffer.take(batch_size)
		var statement: Dictionary = GSLogSqlSchema.insert_statement(
			table, dialect, batch, _context
		)

		var res: GSResult = await driver.execute(
			String(statement["sql"]), statement["params"]
		)

		if res == null:
			res = GSResult.fail(
				GSError.CODE_INTERNAL, "The driver returned nothing."
			)

		if not res.ok:
			# Back at the front, in order, for the next flush. A database that is down
			# usually comes back, and a log that threw the rows away in the meantime is
			# missing exactly the window that explains why it went down.
			_buffer.requeue(batch)
			note_failure(res)
			_sending = false
			return res

		total += batch.size()
		_inserted += batch.size()

	_sending = false
	return GSResult.success(total)


func is_buffered() -> bool:
	return true


func pending() -> int:
	return _buffer.size()


## Deletes rows older than [member retention_days]. Returns what the driver said.
func prune() -> GSResult:
	if retention_days <= 0:
		return GSResult.success(0)
	if driver == null or not _opened:
		return GSResult.fail(GSError.CODE_STATE, "The log database is not open.")

	var cutoff_ms: int = (
		int(Time.get_unix_time_from_system() * 1000.0)
		- retention_days * 86400 * 1000
	)
	var statement: Dictionary = GSLogSqlSchema.prune_statement(
		table, dialect, cutoff_ms
	)
	var res: GSResult = await driver.execute(
		String(statement["sql"]), statement["params"]
	)
	return res if res != null else GSResult.success(0)


## The most recent rows back out of the table, for a console command.
func tail(limit: int = 50, channel: String = "") -> GSResult:
	if driver == null or not driver.has_method("query"):
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED, "This driver cannot read rows back."
		)

	var statement: Dictionary = GSLogSqlSchema.tail_statement(
		table, dialect, limit, channel
	)
	var res: GSResult = await driver.query(
		String(statement["sql"]), statement["params"]
	)
	return res if res != null else GSResult.fail(
		GSError.CODE_INTERNAL, "The driver returned nothing."
	)


func describe() -> Dictionary:
	var out: Dictionary = super()
	out["table"] = table
	out["dialect"] = ["sqlite", "postgres", "mysql"][dialect]
	out["driver"] = (
		String(driver.call("driver_name"))
		if driver != null and driver.has_method("driver_name")
		else ("present" if driver != null else "none")
	)
	out["inserted"] = _inserted
	out["queued"] = _buffer.size()
	out["queue_dropped"] = _buffer.dropped()
	return out
