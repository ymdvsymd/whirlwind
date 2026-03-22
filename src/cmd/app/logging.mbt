// ── Logging ──────────────────────────────────────────────────

///|
/// Extract embedded [TS:HH:MM:SS] prefix from a message.
/// Returns (timestamp, remaining_message). If no prefix found, uses now_timestamp().
fn extract_event_ts(msg : String) -> (String, String) {
  @helpers.extract_event_ts(msg, now_timestamp)
}

///|
/// Timestamped log with ANSI color coding by level
fn log(level : String, msg : String) -> Unit {
  let (ts, actual_msg) = extract_event_ts(msg)
  let color = match level {
    "CALL" => "\u001b[90m"
    "DONE" => "\u001b[36m"
    "ERROR" => "\u001b[31m"
    "WARN" => "\u001b[33m"
    "HEARTBEAT" => "\u001b[1m"
    _ => ""
  }
  if color.is_empty() {
    println("[\{ts}] [\{level}] \{actual_msg}")
  } else {
    println("\{color}[\{ts}] [\{level}] \{actual_msg}\u001b[0m")
  }
  let log_file = get_log_file()
  if not(log_file.is_empty()) {
    append_file_sync(log_file, "[\{ts}] [\{level}] \{actual_msg}\n")
  }
}
