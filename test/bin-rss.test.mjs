// Gate of ADR-0018: one spawn of the binary peaks at 8 MB of resident memory
// or less on a database of 1 000 items with bodies of 200 characters, for the
// read of a reload and for a write with the snapshot after it. The peak is the
// VmHWM of the process image, read from /proc while the process is blocked on
// a stdout pipe nobody drains: by then it has built its whole answer, which it
// holds in memory before writing a byte.
import { test } from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { setTimeout as sleep } from "node:timers/promises"
import { BIN, PROTOCOL, T0, answerOf, call, newDb } from "./lib/bin-fixture.mjs"

const LIMIT_KB = 8 * 1024

function hwmKb(pid) {
  try {
    return Number(/VmHWM:\s+(\d+) kB/.exec(readFileSync(`/proc/${pid}/status`, "utf8"))[1])
  } catch {
    return null
  }
}

// The peak of one request whose answer is larger than the pipe, and the answer.
async function peakOf(dbPath, request) {
  const child = spawn(BIN, [PROTOCOL, "run", dbPath], { env: {}, stdio: ["pipe", "pipe", "pipe"] })
  child.stdout.pause()
  const exited = new Promise((resolve) => child.on("close", resolve))
  child.stdin.end(JSON.stringify(request))
  let peak = null
  let steady = 0
  while (steady < 30) {
    await sleep(10)
    const now = hwmKb(child.pid)
    assert.notEqual(now, null, "the process ended before its answer filled the pipe")
    steady = now === peak ? steady + 1 : 0
    peak = now
  }
  const chunks = []
  child.stdout.on("data", (c) => chunks.push(c))
  child.stdout.resume()
  const code = await exited
  assert.equal(code, 0)
  return { peak, answer: answerOf({ status: code, stdout: Buffer.concat(chunks).toString("utf8"), stderr: "" }) }
}

function item(i) {
  return { id: i + 1, by: "widget", op: "item.add", at: T0, args: { type: "note", title: `Item ${i} café`, body: "Ação e texto ".repeat(20).slice(0, 200) } }
}

test("a spawn peaks at 8 MB or less on 1 000 items of 200 characters, reading or writing", async (t) => {
  const path = newDb(t)
  for (let start = 0; start < 1000; start += 250) {
    const res = call(path, { writes: Array.from({ length: 250 }, (_, i) => item(start + i)) })
    assert.ok(res.results.every((r) => r.err === undefined))
  }
  const read = await peakOf(path, { sync: { since: -1, views: [{ key: "v", filter: "all", query: "cafe" }] } })
  assert.equal(read.answer.snapshot.items.length, 1000)
  assert.equal(read.answer.snapshot.matches.v.length, 1000)
  const write = await peakOf(path, { writes: [item(1000)], sync: { since: -1, views: [] } })
  assert.equal(write.answer.snapshot.items.length, 1001)
  t.diagnostic(`peak RSS: reload ${read.peak} kB, write and snapshot ${write.peak} kB`)
  assert.ok(read.peak <= LIMIT_KB, `the reload peaked at ${read.peak} kB`)
  assert.ok(write.peak <= LIMIT_KB, `the write peaked at ${write.peak} kB`)
})
