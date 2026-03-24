///|
/// Manages milestones and their tasks for the ralph loop
pub struct MilestoneManager {
  milestones : Array[@types.Milestone]
  mut next_task_id : Int
  brief : String
}

///|
/// Create an empty milestone manager
pub fn MilestoneManager::new() -> MilestoneManager {
  { milestones: [], next_task_id: 1, brief: "" }
}

///|
/// Create a milestone manager from explicit parts
pub fn MilestoneManager::from_parts(
  milestones : Array[@types.Milestone],
  next_task_id : Int,
  brief : String,
) -> MilestoneManager {
  { milestones, next_task_id, brief }
}

///|
/// Load milestones from JSON string
pub fn MilestoneManager::load_from_json(
  s : String,
) -> MilestoneManager raise Failure {
  let json = @json.parse(s) catch {
    err => raise Failure::Failure("Invalid milestones JSON: \{err}")
  }
  let milestones : Array[@types.Milestone] = []
  let mut max_id = 0
  match json {
    Object(map) => {
      let brief = match map.get("brief") {
        Some(String(s)) => s
        _ => ""
      }
      match map.get("milestones") {
        Some(Array(arr)) =>
          for item in arr {
            let m = parse_milestone(item)
            for t in m.tasks {
              let num = extract_task_num(t.id)
              if num > max_id {
                max_id = num
              }
            }
            milestones.push(m)
          }
        _ => ()
      }
      { milestones, next_task_id: max_id + 1, brief }
    }
    _ => raise Failure::Failure("Milestones must be a JSON object")
  }
}

///|
/// Serialize milestones to JSON string
pub fn MilestoneManager::to_json(self : MilestoneManager) -> String {
  let obj : Map[String, Json] = {}
  obj["brief"] = self.brief.to_json()
  let milestone_arr : Array[Json] = []
  for m in self.milestones {
    milestone_arr.push(milestone_to_json_value(m))
  }
  obj["milestones"] = Json::array(milestone_arr)
  Json::object(obj).stringify()
}

///|
/// Get the next pending milestone
pub fn MilestoneManager::next_pending_milestone(
  self : MilestoneManager,
) -> @types.Milestone? {
  for m in self.milestones {
    if m.status == @types.MilestoneStatus::Pending ||
      m.status == @types.MilestoneStatus::InProgress {
      return Some(m)
    }
  }
  None
}

///|
/// Check if all milestones are done
pub fn MilestoneManager::all_milestones_done(self : MilestoneManager) -> Bool {
  self.milestones
  .iter()
  .all(fn(m) {
    m.status == @types.MilestoneStatus::Done ||
    m.status is @types.MilestoneStatus::Failed(_)
  })
}

///|
/// Generate a unique task id
pub fn MilestoneManager::gen_task_id(
  self : MilestoneManager,
  milestone_id : String,
) -> String {
  let id = "\{milestone_id}-t\{self.next_task_id}"
  self.next_task_id += 1
  id
}

///|
/// Parse planner output into tasks
pub fn MilestoneManager::parse_planner_output(
  self : MilestoneManager,
  output : String,
  milestone_id : String,
) -> Array[@types.RalphTask] {
  parse_plan_text(self, output, milestone_id)
}

// --- Internal helpers ---

///|
fn parse_milestone(json : Json) -> @types.Milestone {
  let id = @util.get_string(json, "id", "")
  let goal = @util.get_string(json, "goal", "")
  let status_str = @util.get_string(json, "status", "pending")
  let status : @types.MilestoneStatus = match status_str {
    "in_progress" => InProgress
    "done" => Done
    "failed" => Failed(@util.get_string(json, "failure_reason", "unknown"))
    _ => Pending
  }
  let tasks : Array[@types.RalphTask] = []
  let summary = @util.get_string(json, "summary", "")
  match json {
    Object(map) =>
      match map.get("tasks") {
        Some(Array(arr)) =>
          for item in arr {
            tasks.push(parse_ralph_task(item))
          }
        _ => ()
      }
    _ => ()
  }
  { id, goal, status, tasks, summary }
}

///|
fn parse_ralph_task(json : Json) -> @types.RalphTask {
  let id = @util.get_string(json, "id", "")
  let description = @util.get_string(json, "description", "")
  let wave = @util.get_int(json, "wave", 0)
  let status_str = @util.get_string(json, "status", "pending")
  let status : @types.TaskStatus = match status_str {
    "in_progress" => Pending
    "done" => Done
    "failed" => Failed(@util.get_string(json, "failure_reason", "unknown"))
    _ => Pending
  }
  let result : String? = match json {
    Object(map) =>
      match map.get("result") {
        Some(String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
  let scope : Array[String] = match json {
    Object(map) =>
      match map.get("scope") {
        Some(Array(items)) => {
          let result : Array[String] = []
          for item in items {
            match item {
              String(s) => result.push(s)
              _ => ()
            }
          }
          result
        }
        _ => []
      }
    _ => []
  }
  { id, description, wave, scope, status, result }
}

///|
fn milestone_to_json_value(m : @types.Milestone) -> Json {
  let (status_str, failure_reason) : (String, String?) = match m.status {
    Pending => ("pending", None)
    InProgress => ("in_progress", None)
    Done => ("done", None)
    Failed(reason) => ("failed", Some(reason))
  }
  let task_arr : Array[Json] = []
  for t in m.tasks {
    task_arr.push(ralph_task_to_json_value(t))
  }
  let obj : Map[String, Json] = {}
  obj["id"] = m.id.to_json()
  obj["goal"] = m.goal.to_json()
  obj["status"] = status_str.to_json()
  match failure_reason {
    Some(reason) => obj["failure_reason"] = reason.to_json()
    None => ()
  }
  obj["tasks"] = Json::array(task_arr)
  obj["summary"] = m.summary.to_json()
  Json::object(obj)
}

///|
fn ralph_task_to_json_value(t : @types.RalphTask) -> Json {
  let (status_str, failure_reason) : (String, String?) = match t.status {
    Pending => ("pending", None)
    InProgress(_) => ("in_progress", None)
    Done => ("done", None)
    Failed(reason) => ("failed", Some(reason))
  }
  let result_json : Json = match t.result {
    Some(s) => s.to_json()
    None => Json::null()
  }
  let obj : Map[String, Json] = {}
  obj["id"] = t.id.to_json()
  obj["description"] = t.description.to_json()
  obj["wave"] = t.wave.to_json()
  obj["status"] = status_str.to_json()
  match failure_reason {
    Some(reason) => obj["failure_reason"] = reason.to_json()
    None => ()
  }
  obj["result"] = result_json
  if not(t.scope.is_empty()) {
    let scope_arr : Array[Json] = []
    for path in t.scope {
      scope_arr.push(path.to_json())
    }
    obj["scope"] = Json::array(scope_arr)
  }
  Json::object(obj)
}

///|
fn extract_task_num(id : String) -> Int {
  // Extract number after last 't' in id like "m1-t3"
  let chars = id.to_array()
  let mut last_t = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == 't' {
      last_t = i
    }
  }
  if last_t < 0 || last_t + 1 >= chars.length() {
    return 0
  }
  let mut num = 0
  for i = last_t + 1; i < chars.length(); i = i + 1 {
    let ch = chars[i]
    if ch >= '0' && ch <= '9' {
      num = num * 10 + (ch.to_int() - '0'.to_int())
    } else {
      break
    }
  }
  num
}

///|
/// Parse planner text output in WAVE format
fn parse_plan_text(
  mgr : MilestoneManager,
  output : String,
  milestone_id : String,
) -> Array[@types.RalphTask] {
  let tasks : Array[@types.RalphTask] = []
  let mut current_wave = 0
  let mut saw_wave_header = false
  let mut found_wave_tasks = false
  let lines = @util.split_lines(output)
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    let trimmed = @util.trim(line)
    if trimmed.is_empty() {
      i = i + 1
      continue
    }
    // Stop at "---" only after we've started parsing actual WAVE tasks.
    if is_separator(trimmed) && found_wave_tasks {
      break
    }
    // Strip markdown formatting before checking wave prefix
    let stripped = strip_markdown_prefix(trimmed)
    // Check for "WAVE N:" header
    if has_wave_prefix(stripped) {
      let num = parse_wave_number(stripped)
      if num >= 0 {
        current_wave = num
        saw_wave_header = true
      }
      i = i + 1
      continue
    }
    if not(saw_wave_header) {
      i = i + 1
      continue
    }
    // Check for numbered items: "1. description" or "- description"
    let desc = parse_list_item(trimmed)
    if desc.length() > 0 {
      found_wave_tasks = true
      let id = mgr.gen_task_id(milestone_id)
      tasks.push({
        id,
        description: desc,
        wave: current_wave,
        scope: [],
        status: @types.TaskStatus::Pending,
        result: None,
      })
      i = i + 1
      if i < lines.length() {
        match parse_scope_line(lines[i]) {
          Some(paths) => {
            let last_idx = tasks.length() - 1
            let task = tasks[last_idx]
            tasks[last_idx] = { ..task, scope: paths }
            i = i + 1
          }
          None => ()
        }
      }
      continue
    }
    i = i + 1
  }
  tasks
}

///|
fn is_separator(s : String) -> Bool {
  let chars = s.to_array()
  if chars.length() < 3 {
    return false
  }
  for ch in chars {
    if ch != '-' {
      return false
    }
  }
  true
}

///|
fn strip_markdown_prefix(s : String) -> String {
  let mut result = s
  // Strip leading "## ", "# ", etc.
  while result.has_prefix("#") {
    result = @util.trim(String::from_array(result.to_array()[1:]))
  }
  // Strip bold markers "**"
  while result.has_prefix("**") {
    result = String::from_array(result.to_array()[2:])
  }
  result
}

///|
fn has_wave_prefix(s : String) -> Bool {
  s.has_prefix("WAVE ") || s.has_prefix("wave ") || s.has_prefix("Wave ")
}

///|
fn parse_wave_number(s : String) -> Int {
  // Extract number after "WAVE "
  let chars = s.to_array()
  let mut i = 5 // after "WAVE "
  let mut num = 0
  let mut found = false
  while i < chars.length() {
    let ch = chars[i]
    if ch >= '0' && ch <= '9' {
      num = num * 10 + (ch.to_int() - '0'.to_int())
      found = true
    } else {
      break
    }
    i += 1
  }
  if found {
    num
  } else {
    -1
  }
}

///|
fn parse_list_item(s : String) -> String {
  let chars = s.to_array()
  let len = chars.length()
  // Check "N. description"
  let mut i = 0
  if i < len && chars[i] >= '0' && chars[i] <= '9' {
    while i < len && chars[i] >= '0' && chars[i] <= '9' {
      i += 1
    }
    if i < len && chars[i] == '.' {
      i += 1
      // skip spaces
      while i < len && chars[i] == ' ' {
        i += 1
      }
      return @util.trim(String::from_array(chars[i:]))
    }
  }
  // Check "- description"
  if len > 1 && chars[0] == '-' && chars[1] == ' ' {
    return @util.trim(String::from_array(chars[2:]))
  }
  ""
}

///|
fn parse_scope_line(s : String) -> Array[String]? {
  let trimmed = @util.trim(s)
  if not(
      trimmed.has_prefix("SCOPE:") ||
      trimmed.has_prefix("scope:") ||
      trimmed.has_prefix("Scope:"),
    ) {
    return None
  }

  let rest = @util.trim(String::from_array(trimmed.to_array()[6:]))
  let items : Array[String] = []
  for part_view in rest.split(",") {
    let part = @util.trim(part_view.to_string())
    if not(part.is_empty()) {
      items.push(part)
    }
  }
  Some(items)
}
