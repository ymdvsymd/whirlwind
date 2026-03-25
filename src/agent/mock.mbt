///|
/// MockBackend for testing with deterministic responses
pub struct MockBackend {
  responses : Map[String, String] // task pattern -> response
  default_response : String
  call_history : Array[(String, String)] // (task, system_prompt)
}

///|
/// Create a new MockBackend with default response
pub fn MockBackend::new(
  default_response? : String = "mock response",
) -> MockBackend {
  { responses: {}, default_response, call_history: [] }
}

///|
/// Add a response for a specific task pattern
pub fn MockBackend::add_response(
  self : MockBackend,
  task_pattern : String,
  response : String,
) -> Unit {
  self.responses[task_pattern] = response
}

///|
/// Get the call history
pub fn MockBackend::get_history(self : MockBackend) -> Array[(String, String)] {
  self.call_history
}

///|
/// Find matching response for the task
fn MockBackend::find_response(self : MockBackend, task : String) -> String {
  // Simple prefix matching
  for entry in self.responses {
    let (pattern, response) = entry
    if task.contains(pattern) {
      return response
    }
  }
  self.default_response
}

///|
/// AgentBackend implementation for MockBackend
impl AgentBackend for MockBackend with run(self, task, system_prompt, on_output) {
  self.call_history.push((task, system_prompt))
  on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Running))
  let response = self.find_response(task)
  on_output(@types.AgentEvent::OutputLine(response))
  on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Completed))
  { content: response, status: Completed, error: None, session_id: "" }
}

///|
/// AgentBackend implementation for MockBackend
impl AgentBackend for MockBackend with name(_self) {
  "mock"
}

///|
impl AgentBackend for MockBackend with set_session_id(_self, _sid) {

}

///|
impl AgentBackend for MockBackend with get_session_id(_self) {
  ""
}

///|
/// Wrap in BoxedBackend for dynamic dispatch
pub fn MockBackend::boxed(self : MockBackend) -> BoxedBackend {
  BoxedBackend::new(self)
}

///|
/// FailingMockBackend always returns a failure
pub struct FailingMockBackend {
  error_msg : String
  mut call_count : Int
}

///|
/// Create a new FailingMockBackend
pub fn FailingMockBackend::new(
  error_msg? : String = "mock error",
) -> FailingMockBackend {
  { error_msg, call_count: 0 }
}

///|
/// AgentBackend implementation for FailingMockBackend
impl AgentBackend for FailingMockBackend with run(
  self,
  _task,
  _system_prompt,
  on_output,
) {
  self.call_count += 1
  on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Running))
  on_output(
    @types.AgentEvent::StatusChange(@types.AgentStatus::Failed(self.error_msg)),
  )
  @types.AgentResult::failed(self.error_msg)
}

///|
/// AgentBackend implementation for FailingMockBackend
impl AgentBackend for FailingMockBackend with name(_self) {
  "failing-mock"
}

///|
impl AgentBackend for FailingMockBackend with set_session_id(_self, _sid) {

}

///|
impl AgentBackend for FailingMockBackend with get_session_id(_self) {
  ""
}

///|
/// Wrap in BoxedBackend for dynamic dispatch
pub fn FailingMockBackend::boxed(self : FailingMockBackend) -> BoxedBackend {
  BoxedBackend::new(self)
}

///|
/// SequenceMockBackend returns responses in order, cycling back to the last one
pub struct SequenceMockBackend {
  responses : Array[String]
  mut call_index : Int
}

///|
pub fn SequenceMockBackend::new(
  responses : Array[String],
) -> SequenceMockBackend {
  { responses, call_index: 0 }
}

///|
impl AgentBackend for SequenceMockBackend with run(
  self,
  _task,
  _system_prompt,
  on_output,
) {
  let idx = if self.call_index < self.responses.length() {
    self.call_index
  } else {
    self.responses.length() - 1
  }
  let response = self.responses[idx]
  self.call_index += 1
  on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Running))
  on_output(@types.AgentEvent::OutputLine(response))
  on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Completed))
  { content: response, status: Completed, error: None, session_id: "" }
}

///|
impl AgentBackend for SequenceMockBackend with name(_self) {
  "sequence-mock"
}

///|
impl AgentBackend for SequenceMockBackend with set_session_id(_self, _sid) {

}

///|
impl AgentBackend for SequenceMockBackend with get_session_id(_self) {
  ""
}

///|
pub fn SequenceMockBackend::boxed(self : SequenceMockBackend) -> BoxedBackend {
  BoxedBackend::new(self)
}

///|
/// FailNTimesMockBackend fails for the first N calls, then returns success
pub struct FailNTimesMockBackend {
  fail_count : Int
  error_msg : String
  success_response : String
  mut call_count : Int
}

///|
pub fn FailNTimesMockBackend::new(
  fail_count : Int,
  error_msg? : String = "mock error",
  success_response? : String = "mock success",
) -> FailNTimesMockBackend {
  { fail_count, error_msg, success_response, call_count: 0 }
}

///|
impl AgentBackend for FailNTimesMockBackend with run(
  self,
  _task,
  _system_prompt,
  on_output,
) {
  self.call_count += 1
  on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Running))
  if self.call_count <= self.fail_count {
    on_output(
      @types.AgentEvent::StatusChange(
        @types.AgentStatus::Failed(self.error_msg),
      ),
    )
    @types.AgentResult::failed(self.error_msg)
  } else {
    on_output(@types.AgentEvent::OutputLine(self.success_response))
    on_output(@types.AgentEvent::StatusChange(@types.AgentStatus::Completed))
    {
      content: self.success_response,
      status: Completed,
      error: None,
      session_id: "",
    }
  }
}

///|
impl AgentBackend for FailNTimesMockBackend with name(_self) {
  "fail-n-times-mock"
}

///|
impl AgentBackend for FailNTimesMockBackend with set_session_id(_self, _sid) {

}

///|
impl AgentBackend for FailNTimesMockBackend with get_session_id(_self) {
  ""
}

///|
pub fn FailNTimesMockBackend::boxed(
  self : FailNTimesMockBackend,
) -> BoxedBackend {
  BoxedBackend::new(self)
}
