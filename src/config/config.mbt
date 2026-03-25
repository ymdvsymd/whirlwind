///|
/// Project configuration
pub(all) struct ProjectConfig {
  agents : Array[@types.AgentConfig]
  parse_warnings : Array[String]
  milestones_path : String?
  max_rework_attempts : Int
}

///|
/// Known valid agent kind strings
let valid_agent_kinds : Array[String] = ["claude-code", "codex", "mock"]

///|
/// Known valid agent role strings
let valid_agent_roles : Array[String] = [
  "dev", "builder", "review", "planner", "verifier",
]

///|
/// Parse AgentKind from string
fn parse_agent_kind(s : String) -> @types.AgentKind {
  match s {
    "claude-code" => ClaudeCode
    "codex" => Codex
    _ => Mock
  }
}

///|
/// Parse AgentRole from string
fn parse_agent_role(s : String) -> @types.AgentRole {
  match s {
    "dev" | "builder" => Builder
    "review" => Review
    "planner" => Planner
    "verifier" => Verifier
    _ => Builder
  }
}

///|
/// Parse a single agent config from JSON, collecting warnings for unknown values
fn parse_agent_config(
  json : Json,
  warnings : Array[String],
) -> @types.AgentConfig {
  let id = @util.get_string(json, "id", "")
  let kind_str = @util.get_string(json, "kind", "mock")
  if not(valid_agent_kinds.contains(kind_str)) {
    warnings.push(
      "Agent '\{id}': unknown kind '\{kind_str}', defaulting to Mock",
    )
  }
  let kind = parse_agent_kind(kind_str)
  let role_str = @util.get_string(json, "role", "dev")
  if not(valid_agent_roles.contains(role_str)) {
    warnings.push(
      "Agent '\{id}': unknown role '\{role_str}', defaulting to Builder",
    )
  }
  let role = parse_agent_role(role_str)
  let model = @util.get_string_opt(json, "model")
  { id, kind, role, model }
}

///|
/// Parse project config from JSON string
pub fn ProjectConfig::from_json_string(
  s : String,
) -> ProjectConfig raise Failure {
  let json = @json.parse(s) catch {
    err => raise Failure::Failure("Invalid JSON: \{err}")
  }
  ProjectConfig::from_json(json)
}

///|
/// Parse project config from Json value
pub fn ProjectConfig::from_json(json : Json) -> ProjectConfig raise Failure {
  match json {
    Object(map) => {
      let agents : Array[@types.AgentConfig] = []
      let parse_warnings : Array[String] = []
      match map.get("agents") {
        Some(Array(arr)) =>
          for item in arr {
            agents.push(parse_agent_config(item, parse_warnings))
          }
        _ => ()
      }
      let milestones_path = @util.get_string_opt(json, "milestones_path")
      let max_rework_attempts = @util.get_int(json, "max_rework_attempts", 3)
      { agents, parse_warnings, milestones_path, max_rework_attempts }
    }
    _ => raise Failure::Failure("Config must be a JSON object")
  }
}

///|
/// Create a default config (empty agents)
pub fn ProjectConfig::default() -> ProjectConfig {
  {
    agents: [],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
}

///|
/// Preset for ralph loop: planner=claude-code, builder=claude-code, verifier=codex
pub fn ProjectConfig::preset_ralph() -> ProjectConfig {
  let planner : @types.AgentConfig = {
    id: "planner",
    kind: ClaudeCode,
    role: Planner,
    model: None,
  }
  let builder : @types.AgentConfig = {
    id: "builder",
    kind: ClaudeCode,
    role: Builder,
    model: None,
  }
  let verifier : @types.AgentConfig = {
    id: "verifier",
    kind: Codex,
    role: Verifier,
    model: None,
  }
  {
    agents: [planner, builder, verifier],
    parse_warnings: [],
    milestones_path: None,
    max_rework_attempts: 3,
  }
}

///|
/// Apply default models for agents that have no model specified.
/// ClaudeCode: planner/builder → "sonnet", verifier/review → "sonnet"
/// Codex/Mock: no defaults (SDK handles it)
pub fn ProjectConfig::apply_default_models(
  self : ProjectConfig,
) -> ProjectConfig {
  let agents : Array[@types.AgentConfig] = []
  for agent in self.agents {
    let model = match agent.model {
      Some(_) => agent.model
      None =>
        match agent.kind {
          ClaudeCode =>
            match agent.role {
              Planner | Builder => Some("sonnet")
              Verifier | Review => Some("sonnet")
            }
          _ => None
        }
    }
    agents.push({ ..agent, model, })
  }
  { ..self, agents, }
}

///|
/// Check if a model name looks like a Claude model
fn is_claude_model(model : String) -> Bool {
  model.contains("opus") || model.contains("sonnet") || model.contains("haiku")
}

///|
/// Check if a model name looks like an OpenAI/Codex model
fn is_codex_model(model : String) -> Bool {
  model.contains("gpt") || model.contains("codex")
}

///|
/// Validate the config. Returns errors and parse warnings.
pub fn ProjectConfig::validate(self : ProjectConfig) -> Array[String] {
  let errors : Array[String] = []
  // Include any parse warnings (unknown kind/role values)
  for w in self.parse_warnings {
    errors.push(w)
  }
  if self.agents.is_empty() {
    errors.push("No agents configured")
  }
  let ids : Map[String, Bool] = {}
  for agent in self.agents {
    if agent.id.is_empty() {
      errors.push("Agent has empty id")
    }
    if ids.get(agent.id) is Some(true) {
      errors.push("Duplicate agent id: \{agent.id}")
    }
    ids[agent.id] = true
  }
  // Check for at least one dev agent
  let has_builder = self.agents.iter().any(fn(a) { a.role == Builder })
  if not(has_builder) && not(self.agents.is_empty()) {
    errors.push("No builder agent configured")
  }
  // Planner is required
  let has_planner = self.agents.iter().any(fn(a) { a.role == Planner })
  if not(has_planner) && not(self.agents.is_empty()) {
    errors.push("No planner agent configured")
  }
  // Kind + model combination checks
  for agent in self.agents {
    match agent.model {
      Some(model) =>
        match agent.kind {
          Mock =>
            errors.push("Agent '\{agent.id}': model is ignored for Mock kind")
          ClaudeCode =>
            if is_codex_model(model) {
              errors.push(
                "Agent '\{agent.id}': model '\{model}' may not be valid for claude-code kind",
              )
            }
          Codex =>
            if is_claude_model(model) {
              errors.push(
                "Agent '\{agent.id}': model '\{model}' may not be valid for codex kind",
              )
            }
        }
      None => ()
    }
  }
  errors
}
