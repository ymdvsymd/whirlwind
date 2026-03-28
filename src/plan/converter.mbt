///|
pub fn convert_to_milestones(
  doc : PlanDocument,
  classifications : Array[SectionClass],
) -> @ralph.MilestoneManager {
  let sb = StringBuilder::new()
  let mut has_brief = false
  if not(doc.intro.is_empty()) {
    sb.write_string(doc.intro)
    has_brief = true
  }

  let milestones : Array[@types.Milestone] = []
  let mut milestone_index = 1

  for i in 0..<doc.sections.length() {
    let section = doc.sections[i]
    let class = classifications[i]
    match class {
      SectionClass::Info => {
        if has_brief {
          sb.write_string("\n\n")
        }
        sb.write_string("## ")
        sb.write_string(section.heading)
        sb.write_string("\n")
        sb.write_string(section.body)
        has_brief = true
      }
      SectionClass::Milestone | SectionClass::Uncertain => {
        milestones.push({
          id: "m\{milestone_index}",
          goal: section.heading + "\n\n" + section.body,
          status: @types.MilestoneStatus::Pending,
          tasks: [],
          summary: "",
          perspectives: [],
        })
        milestone_index += 1
      }
    }
  }

  @ralph.MilestoneManager::from_parts(milestones, 1, sb.to_string())
}
