// ── Task builders ────────────────────────────────────────────

///|
/// Build initial task by reading TODO files in the project
fn build_initial_task_from_todos() -> String {
  let todo_files = [
    "TODO.md", "Agents-todo.md", "AGENTS-TODO.md", "agents-todo.md", "TODO", "todo.md",
  ]
  let buf = StringBuilder::new()
  buf.write_string(
    "You are starting an autonomous development session for this project.\n\n",
  )
  buf.write_string(
    "First, read the following TODO/task files to understand what needs to be done:\n\n",
  )
  let mut found = false
  for file in todo_files {
    match read_file_result(file) {
      Ok(content) =>
        if not(content.is_empty()) {
          found = true
          buf.write_string("## \{file}\n```\n")
          buf.write_string(@display.truncate(content, 3000))
          buf.write_string("\n```\n\n")
        }
      Err(_) => ()
    }
  }
  if not(found) {
    buf.write_string(
      "(No TODO files found. Look at the project structure, README, and recent git history instead.)\n\n",
    )
  }
  let context = gather_review_context()
  if not(context.is_empty()) {
    buf.write_string("## Current Project State\n")
    buf.write_string(context)
  }
  buf.write_string("## Your Task\n")
  buf.write_string(
    "Based on the TODO files and project state above, pick the highest-priority incomplete task and implement it.\n",
  )
  buf.write_string(
    "Make concrete code changes, run tests, and commit when done. Then move to the next task.\n",
  )
  buf.to_string()
}

///|
/// Build a task prompt that directs the agent to read/write the plan file
fn build_plan_file_task(plan_path : String, review_summary : String) -> String {
  let context = gather_review_context()
  @helpers.build_plan_file_task(plan_path, review_summary, context)
}

///|
/// Combine multiple dev outputs into a structured summary
fn join_dev_outputs(outputs : Array[String]) -> String {
  @helpers.join_dev_outputs(outputs)
}

///|
/// Build improvement loop prompt for --rlm mode
fn build_improvement_task(
  prev_output : String,
  current_step : Int,
  total_steps : Int,
  cycle_summary? : String = "",
) -> String {
  let context = gather_review_context()
  @helpers.build_improvement_task(
    prev_output, current_step, total_steps, cycle_summary, context,
  )
}

///|
/// Build a human-readable summary of what happened in this cycle
fn build_cycle_summary(
  iteration : Int,
  dev_outputs : Array[String],
  review_summary : String,
) -> String {
  @helpers.build_cycle_summary(iteration, dev_outputs, review_summary)
}

///|
/// Build the next dev task based on plan/rlm mode
fn build_next_task(
  plan_path : String?,
  rlm : Bool,
  review_summary : String,
  prev_output : String,
  current_step? : Int = 1,
  total_steps? : Int = 1,
  cycle_summary? : String = "",
) -> String {
  match (plan_path, rlm) {
    (Some(path), true) => {
      let base = build_plan_file_task(path, review_summary)
      let improvement = build_improvement_task(
        prev_output,
        current_step,
        total_steps,
        cycle_summary~,
      )
      base + "\n\n" + improvement
    }
    (Some(path), false) => build_plan_file_task(path, review_summary)
    (None, true) =>
      build_improvement_task(
        prev_output,
        current_step,
        total_steps,
        cycle_summary~,
      )
    (None, false) => build_continuation_task(prev_output, review_summary)
  }
}

///|
/// Build a continuation task for the dev agent after review approval
fn build_continuation_task(
  prev_task : String,
  review_summary : String,
) -> String {
  let context = gather_review_context()
  let buf = StringBuilder::new()
  buf.write_string(
    "You are in an autonomous development loop. Your job is to continuously improve this project.\n\n",
  )
  if not(context.is_empty()) {
    buf.write_string("## Current Project State\n")
    buf.write_string(context)
    buf.write_string("\n")
  }
  buf.write_string("## Previous Task (completed)\n")
  buf.write_string(prev_task)
  buf.write_string("\n\n")
  if not(review_summary.is_empty()) {
    buf.write_string("## Review Feedback\n")
    buf.write_string(@display.truncate(review_summary, 2000))
    buf.write_string("\n\n")
  }
  buf.write_string("## Your Task\n")
  buf.write_string(
    "Based on the current project state above (git log, uncommitted changes, previous work), ",
  )
  buf.write_string(
    "identify and implement the single most impactful improvement. ",
  )
  buf.write_string(
    "This could be: fixing bugs, adding tests, improving error handling, ",
  )
  buf.write_string(
    "refactoring, documentation, or implementing a missing feature.\n\n",
  )
  buf.write_string(
    "Look at the actual codebase files, run tests, and make concrete changes. ",
  )
  buf.write_string("Do not just describe what to do — actually do it.\n")
  buf.to_string()
}
