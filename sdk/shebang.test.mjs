import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("bin/whirlwind.js has valid shebang without backslash escaping", () => {
  const buf = readFileSync("bin/whirlwind.js");
  // 先頭2バイトが #! (0x23 0x21) であること
  assert.equal(buf[0], 0x23, "first byte should be # (0x23)");
  assert.equal(
    buf[1],
    0x21,
    "second byte should be ! (0x21), not \\! (0x5c 0x21)",
  );
  // 完全な shebang 行の検証
  const firstLine = buf.toString("utf8").split("\n")[0];
  assert.equal(firstLine, "#!/usr/bin/env node");
});
