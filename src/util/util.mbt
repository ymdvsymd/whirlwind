///| Extract content between XML-style tags.

///|

///| Searches for `<tag_name>...</tag_name>` and returns the content between them.

///| The close tag search starts from after the open tag, preventing cross-tag

///| mismatches when close tag text appears before the open tag.

///|
/// Returns None if either the open tag or the close tag is not found.
pub fn extract_tag_content(text : String, tag_name : String) -> String? {
  let open_tag = "<\{tag_name}>"
  let close_tag = "</\{tag_name}>"
  let open_idx = text.find(open_tag)
  match open_idx {
    Some(start) => {
      let content_start = start + open_tag.length()
      // Search for close tag only in the text after the open tag
      let remaining = text.view(start_offset=content_start).to_string()
      let close_idx = remaining.find(close_tag)
      match close_idx {
        Some(rel_end) =>
          Some(
            text
            .view(
              start_offset=content_start,
              end_offset=content_start + rel_end,
            )
            .to_string(),
          )
        None => None
      }
    }
    None => None
  }
}

///|
/// Get a string from a JSON object
pub fn get_string(json : Json, key : String, default : String) -> String {
  match json {
    Object(map) =>
      match map.get(key) {
        Some(String(s)) => s
        _ => default
      }
    _ => default
  }
}

///|
/// Get an int from a JSON object
pub fn get_int(json : Json, key : String, default : Int) -> Int {
  match json {
    Object(map) =>
      match map.get(key) {
        Some(Number(n, ..)) => n.to_int()
        _ => default
      }
    _ => default
  }
}

///|
/// Get a bool from a JSON object
pub fn get_bool(json : Json, key : String, default : Bool) -> Bool {
  match json {
    Object(map) =>
      match map.get(key) {
        Some(True) => true
        Some(False) => false
        _ => default
      }
    _ => default
  }
}

///|
/// Get an optional string from a JSON object
pub fn get_string_opt(json : Json, key : String) -> String? {
  match json {
    Object(map) =>
      match map.get(key) {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
/// Split a string into lines
pub fn split_lines(s : String) -> Array[String] {
  let lines : Array[String] = []
  let buf = StringBuilder::new()
  for ch in s {
    if ch == '\n' {
      lines.push(buf.to_string())
      buf.reset()
    } else if ch == '\r' {
      // skip
    } else {
      buf.write_char(ch)
    }
  }
  let remaining = buf.to_string()
  if not(remaining.is_empty()) {
    lines.push(remaining)
  }
  lines
}

///|
/// Trim leading and trailing whitespace
pub fn trim(s : String) -> String {
  let chars = s.to_array()
  let len = chars.length()
  let mut start = 0
  while start < len && (chars[start] == ' ' || chars[start] == '\t') {
    start += 1
  }
  let mut end = len
  while end > start && (chars[end - 1] == ' ' || chars[end - 1] == '\t') {
    end -= 1
  }
  if start >= end {
    return ""
  }
  String::from_array(chars[start:end])
}

///|
/// Join strings with a separator
pub fn join_strings(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::new()
  for i, part in parts {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(part)
  }
  buf.to_string()
}

///|
/// Escape a string for JSON output (wraps in quotes)
pub fn json_escape(s : String) -> String {
  let hex_chars = "0123456789abcdef".to_array()
  let buf = StringBuilder::new()
  buf.write_char('"')
  for ch in s {
    match ch {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ =>
        if ch.to_int() < 0x20 {
          let code = ch.to_int()
          buf.write_string("\\u00")
          buf.write_char(hex_chars[code / 16])
          buf.write_char(hex_chars[code % 16])
        } else {
          buf.write_char(ch)
        }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Find the first occurrence of needle in haystack
pub fn find_substring(haystack : String, needle : String) -> Int {
  let h = haystack.to_array()
  let n = needle.to_array()
  if n.length() > h.length() {
    return -1
  }
  for i = 0; i <= h.length() - n.length(); i = i + 1 {
    let mut found = true
    for j = 0; j < n.length(); j = j + 1 {
      if h[i + j] != n[j] {
        found = false
        break
      }
    }
    if found {
      return i
    }
  }
  -1
}

///|
/// Find the first occurrence of needle in haystack starting from offset
pub fn find_substring_from(
  haystack : String,
  needle : String,
  from : Int,
) -> Int {
  let h = haystack.to_array()
  let n = needle.to_array()
  if from + n.length() > h.length() {
    return -1
  }
  for i = from; i <= h.length() - n.length(); i = i + 1 {
    let mut found = true
    for j = 0; j < n.length(); j = j + 1 {
      if h[i + j] != n[j] {
        found = false
        break
      }
    }
    if found {
      return i
    }
  }
  -1
}

///|
/// Extract a substring from start to end index
pub fn substring(s : String, start : Int, end : Int) -> String {
  let chars = s.to_array()
  let actual_start = if start < 0 { 0 } else { start }
  let actual_end = if end > chars.length() { chars.length() } else { end }
  if actual_start >= actual_end {
    return ""
  }
  String::from_array(chars[actual_start:actual_end])
}
