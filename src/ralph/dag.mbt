///|
/// Compute DAG layers using Kahn's algorithm (BFS topological sort).
///
/// Takes an array of tasks with depends_on edges.
/// Returns a tuple of:
///   - Map[String, Int]: task ID → layer number
///   - Array[String]: task IDs involved in cycles or self-references
///   - Array[String]: warning messages (non-existent references, self-references)
///
/// Self-references are reported as cycle errors and the edge is ignored.
/// Non-existent references produce a warning and the edge is ignored.
/// Tasks involved in true cycles are assigned to layer 0 (graceful fallback).
pub fn compute_layers(
  tasks : Array[@types.RalphTask],
) -> (Map[String, Int], Array[String], Array[String]) {
  let task_ids : Map[String, Bool] = {}
  for t in tasks {
    task_ids[t.id] = true
  }

  let warnings : Array[String] = []
  let self_ref_set : Map[String, Bool] = {}

  // Build adjacency list (successor map) and in-degree map
  let successors : Map[String, Array[String]] = {}
  let in_degree : Map[String, Int] = {}
  for t in tasks {
    successors[t.id] = []
    in_degree[t.id] = 0
  }
  for t in tasks {
    for dep in t.depends_on {
      // Detect self-references: report as cycle error, skip edge
      if dep == t.id {
        if not(self_ref_set.contains(t.id)) {
          self_ref_set[t.id] = true
          warnings.push("Self-reference: \{t.id} depends on itself")
        }
        continue
      }
      // Detect non-existent references: warn and skip edge
      if not(task_ids.contains(dep)) {
        warnings.push(
          "Non-existent reference: \{t.id} depends on \{dep} which does not exist",
        )
        continue
      }
      // dep → t.id (t depends on dep, so dep is predecessor)
      match successors.get(dep) {
        Some(succs) => succs.push(t.id)
        None => ()
      }
      match in_degree.get(t.id) {
        Some(d) => in_degree[t.id] = d + 1
        None => ()
      }
    }
  }

  // BFS: process layer by layer
  let layers : Map[String, Int] = {}
  let mut current : Array[String] = []

  // Seed with all nodes having in-degree 0
  for t in tasks {
    match in_degree.get(t.id) {
      Some(0) => current.push(t.id)
      _ => ()
    }
  }

  let mut layer = 0
  let mut processed = 0
  while not(current.is_empty()) {
    let next : Array[String] = []
    for node in current {
      layers[node] = layer
      processed = processed + 1
      match successors.get(node) {
        Some(succs) =>
          for succ in succs {
            match in_degree.get(succ) {
              Some(d) => {
                let new_d = d - 1
                in_degree[succ] = new_d
                if new_d == 0 {
                  next.push(succ)
                }
              }
              None => ()
            }
          }
        None => ()
      }
    }
    current = next
    layer = layer + 1
  }

  // Detect cycle: any unprocessed tasks are in a cycle
  let cycle_tasks : Array[String] = []
  if processed < tasks.length() {
    for t in tasks {
      if not(layers.contains(t.id)) {
        cycle_tasks.push(t.id)
        // Fallback: assign cycle tasks to layer 0
        layers[t.id] = 0
      }
    }
  }
  // Include self-referencing tasks in cycle_tasks
  for entry in self_ref_set {
    let (id, _) = entry
    if not(cycle_tasks.contains(id)) {
      cycle_tasks.push(id)
    }
  }

  (layers, cycle_tasks, warnings)
}

///|
/// Generate implicit dependency edges from scope overlaps.
///
/// For each group of tasks sharing a scoped file, creates a chain of edges
/// so that overlapping tasks are serialized in their original order.
/// For example, if tasks [t1, t2, t3] all touch "shared.ts",
/// returns edges [(t1, t2), (t2, t3)] meaning t2 depends on t1, t3 depends on t2.
///
/// Returns an array of (from_id, to_id) pairs where to_id should depend on from_id.
pub fn add_scope_edges(
  tasks : Array[@types.RalphTask],
) -> Array[(String, String)] {
  let overlaps = detect_scope_overlaps(tasks)
  let edges : Array[(String, String)] = []
  let seen : Map[String, Bool] = {}
  for overlap in overlaps {
    let (_, task_ids) = overlap
    // Chain: task_ids[0] → task_ids[1] → task_ids[2] → ...
    for i in 1..<task_ids.length() {
      let from = task_ids[i - 1]
      let to = task_ids[i]
      let key = from + "->" + to
      if not(seen.contains(key)) {
        seen[key] = true
        edges.push((from, to))
      }
    }
  }
  edges
}
