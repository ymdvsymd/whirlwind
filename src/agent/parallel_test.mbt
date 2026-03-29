// ── parse_jsonl_result tests ──────────────────────────────────

///|
test "parse_jsonl_result with valid text_delta JSONL produces Completed result" {
  let events : Array[String] = []
  let jsonl =
    #|{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello world"}}}
    #|{"type":"result","subtype":"success","total_cost_usd":0.01}
  let result = @agent.parse_jsonl_result(jsonl, fn(event) {
    match event {
      @types.AgentEvent::StatusChange(s) =>
        events.push("status:" + s.to_string())
      @types.AgentEvent::OutputLine(s) => events.push("line:" + s)
      _ => ()
    }
  })
  inspect(result.content, content="hello world")
  inspect(result.status, content="Completed")
  inspect(result.error, content="None")
  assert_true(events.contains("status:Completed"))
}

///|
test "parse_jsonl_result with empty JSONL returns empty Completed result" {
  let statuses : Array[String] = []
  let result = @agent.parse_jsonl_result("", fn(event) {
    match event {
      @types.AgentEvent::StatusChange(s) => statuses.push(s.to_string())
      _ => ()
    }
  })
  inspect(result.content, content="")
  inspect(result.status, content="Completed")
  inspect(result.error, content="None")
  assert_true(statuses.contains("Completed"))
}

///|
test "parse_jsonl_result with ERROR: prefix returns Failed result" {
  let statuses : Array[String] = []
  let result = @agent.parse_jsonl_result("ERROR: subprocess crashed", fn(
    event,
  ) {
    match event {
      @types.AgentEvent::StatusChange(s) => statuses.push(s.to_string())
      _ => ()
    }
  })
  inspect(result.content, content="")
  inspect(result.error, content="Some(\"ERROR: subprocess crashed\")")
  // Status should be Failed
  match result.status {
    @types.AgentStatus::Failed(_) => ()
    _ => assert_true(false, msg="expected Failed status")
  }
}

///|
test "parse_jsonl_result with is_error result returns Failed" {
  let events : Array[String] = []
  let jsonl =
    #|{"type":"result","subtype":"error","is_error":true,"result":"something went wrong"}
  let result = @agent.parse_jsonl_result(jsonl, fn(event) {
    match event {
      @types.AgentEvent::StatusChange(s) => events.push(s.to_string())
      _ => ()
    }
  })
  match result.status {
    @types.AgentStatus::Failed(msg) =>
      inspect(msg, content="something went wrong")
    _ => assert_true(false, msg="expected Failed status")
  }
  inspect(result.error, content="Some(\"something went wrong\")")
}

///|
test "parse_jsonl_result captures session_id from JSONL" {
  let session_ids : Array[String] = []
  let jsonl =
    #|{"type":"system","subtype":"init","model":"test","tools":[],"session_id":"sess-abc123"}
  let result = @agent.parse_jsonl_result(jsonl, fn(event) {
    match event {
      @types.AgentEvent::SessionId(sid) => session_ids.push(sid)
      _ => ()
    }
  })
  inspect(result.session_id, content="sess-abc123")
  assert_true(session_ids.contains("sess-abc123"))
}

///|
test "parse_jsonl_result skips blank lines in JSONL" {
  let jsonl =
    #|
    #|{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}}
    #|
    #|{"type":"result","subtype":"success"}
    #|
  let result = @agent.parse_jsonl_result(jsonl, fn(_) {  })
  inspect(result.content, content="ok")
  inspect(result.status, content="Completed")
}

///|
test "parse_jsonl_result with multi-line content accumulates text" {
  let jsonl =
    #|{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"line1\n"}}}
    #|{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"line2"}}}
  let result = @agent.parse_jsonl_result(jsonl, fn(_) {  })
  inspect(result.content, content="line1\nline2")
}

///|
test "parse_jsonl_result with invalid JSON lines silently skips them" {
  let jsonl =
    #|not valid json
    #|{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"valid"}}}
  let result = @agent.parse_jsonl_result(jsonl, fn(_) {  })
  inspect(result.content, content="valid")
  inspect(result.status, content="Completed")
}

// ── run_parallel_sequential tests ──────────────────────────────────

///|
test "run_parallel_sequential executes tasks in order via mock backend" {
  let mock = @agent.MockBackend::new()
  mock.add_response("alpha", "result-alpha")
  mock.add_response("beta", "result-beta")
  let boxed = mock.boxed()
  let results = @agent.run_parallel(
    boxed,
    [("alpha task", "sys-a"), ("beta task", "sys-b")],
    fn(_) {  },
  )
  assert_eq(results.length(), 2)
  inspect(results[0].content, content="result-alpha")
  inspect(results[1].content, content="result-beta")
  // Verify all completed successfully
  inspect(results[0].status, content="Completed")
  inspect(results[1].status, content="Completed")
}

///|
test "run_parallel_sequential records call history" {
  let mock = @agent.MockBackend::new()
  let boxed = mock.boxed()
  ignore(
    @agent.run_parallel(
      boxed,
      [("task-one", "prompt-one"), ("task-two", "prompt-two")],
      fn(_) {  },
    ),
  )
  let history = mock.get_history()
  assert_eq(history.length(), 2)
  let (t1, p1) = history[0]
  inspect(t1, content="task-one")
  inspect(p1, content="prompt-one")
  let (t2, p2) = history[1]
  inspect(t2, content="task-two")
  inspect(p2, content="prompt-two")
}

///|
test "run_parallel_sequential with empty tasks returns empty results" {
  let mock = @agent.MockBackend::new()
  let boxed = mock.boxed()
  let results = @agent.run_parallel(boxed, [], fn(_) {  })
  assert_eq(results.length(), 0)
}

///|
test "run_parallel_sequential with failing backend returns all failures" {
  let mock = @agent.FailingMockBackend::new(error_msg="backend down")
  let boxed = mock.boxed()
  let results = @agent.run_parallel(boxed, [("a", ""), ("b", ""), ("c", "")], fn(
    _,
  ) {

  })
  assert_eq(results.length(), 3)
  for result in results {
    match result.status {
      @types.AgentStatus::Failed(msg) => inspect(msg, content="backend down")
      _ => assert_true(false, msg="expected Failed status")
    }
  }
}

// ── run_parallel emits events correctly ──────────────────────────────────

///|
test "run_parallel emits status events for each task" {
  let mock = @agent.MockBackend::new()
  mock.add_response("job1", "done1")
  let boxed = mock.boxed()
  let statuses : Array[String] = []
  let results = @agent.run_parallel(boxed, [("job1", "")], fn(event) {
    match event {
      @types.AgentEvent::StatusChange(s) => statuses.push(s.to_string())
      _ => ()
    }
  })
  assert_eq(results.length(), 1)
  inspect(results[0].content, content="done1")
  // MockBackend emits Running then Completed per task
  assert_true(statuses.contains("Running"))
  assert_true(statuses.contains("Completed"))
}
