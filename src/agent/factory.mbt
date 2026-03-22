///|
/// Create a BoxedBackend from AgentConfig
pub fn create_backend(config : @types.AgentConfig) -> BoxedBackend {
  match config.kind {
    ClaudeCode => {
      let model = config.model.unwrap_or("")
      SubprocessBackend::new(ClaudeCode, model~).boxed()
    }
    Codex => {
      let model = config.model.unwrap_or("")
      SubprocessBackend::new(Codex, model~).boxed()
    }
    Mock =>
      match config.role {
        Planner =>
          MockBackend::new(default_response="WAVE 0:\n1. Mock planned task").boxed()
        Verifier => MockBackend::new(default_response="<wave_approved>").boxed()
        _ => MockBackend::new().boxed()
      }
  }
}

///|
/// Create backends map from agent configs
pub fn create_backends(
  agents : Array[@types.AgentConfig],
) -> Map[String, BoxedBackend] {
  let backends : Map[String, BoxedBackend] = {}
  for agent in agents {
    backends[agent.id] = create_backend(agent)
  }
  backends
}
