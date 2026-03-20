#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const outputDir = process.argv[2];
if (!outputDir) {
  console.error('Usage: node inject-plan-context.js <output_dir>');
  process.exit(1);
}

const VERIFICATION_SCOPE =
  '\n\n---\n## Verification Scope\n' +
  'This milestone may be split into multiple waves. Each wave is verified independently.\n' +
  'The "Wave Results" section below contains ALL tasks for the current wave.\n' +
  'Verify ONLY the tasks listed in Wave Results. Do NOT reject a wave because ' +
  'tasks mentioned in the Plan Context are not yet implemented — they belong to other waves ' +
  'and will be verified separately.\n';

const planPath = path.join(outputDir, 'plan-en.md');
const skeletonPath = path.join(outputDir, 'milestones-skeleton.json');
const outputPath = path.join(outputDir, 'milestones.json');

if (!fs.existsSync(planPath)) {
  console.error(`Error: ${planPath} not found`);
  process.exit(1);
}
if (!fs.existsSync(skeletonPath)) {
  console.error(`Error: ${skeletonPath} not found`);
  process.exit(1);
}

let data;
try {
  data = JSON.parse(fs.readFileSync(skeletonPath, 'utf-8'));
} catch (e) {
  console.error(`Error: Failed to parse ${skeletonPath}: ${e.message}`);
  process.exit(1);
}

const plan = fs.readFileSync(planPath, 'utf-8');
const planSuffix = '\n\n---\n## Plan Context\n' + plan;

for (const m of data.milestones) {
  m.goal += VERIFICATION_SCOPE + planSuffix;
  for (const t of m.tasks) {
    t.description += planSuffix;
  }
}

fs.writeFileSync(outputPath, JSON.stringify(data, null, 2));
fs.unlinkSync(skeletonPath);
console.log(`Done: ${outputPath}`);
