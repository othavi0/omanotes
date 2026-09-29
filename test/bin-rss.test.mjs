// Gate of ADR-0018: the memory of one spawn. The binary writes the snapshot as
// it reads it, so its own memory (RssAnon: the GC heap, SQLite's cache, the
// stacks) does not grow with the database. VmHWM, the peak of the whole
// process, also counts the pages of libc, libsqlite3 and libm, which the
// system shares and a package update moves: its growth from 1 000 to 2 000
// items measured from -276 to +356 kB over 20 runs, so it is reported and not
// gated.
//
// The child's stdout is a FIFO filled before the spawn, so the child blocks on
// its first write, line 1, right after the migration and the writes. The test
// then drains it 64 KiB at a time and reads /proc/<pid>/status each time the
// child is blocked again. RssAnon is the largest of those readings, VmHWM the
// last one.
import { test } from "node:test"
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import { closeSync, constants, openSync, readFileSync, readSync, writeSync } from "node:fs"
import { join } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"
import { BIN, PROTOCOL, T0, answerOf, call, newDb, tempDb, tempDir } from "./lib/bin-fixture.mjs"

const ANON_LIMIT_KB = 3 * 1024
const WRITE_ANON_LIMIT_KB = 16 * 1024
const ANON_SLOPE_KB = 128

function memory(pid) {
  try {
    const text = readFileSync(`/proc/${pid}/status`, "utf8")
    const kb = (name) => Number(new RegExp(`${name}:\\s+(\\d+) kB`).exec(text)[1])
    return { anon: kb("RssAnon"), hwm: kb("VmHWM") }
  } catch {
    return null
  }
}

// The reading once it stops changing: the child is blocked on the pipe. null once it exited.
async function blocked(pid) {
  let last = null
  let same = 0
  while (same < 5) {
    await sleep(4)
    const now = memory(pid)
    if (now === null) return last
    same = last && now.anon === last.anon && now.hwm === last.hwm ? same + 1 : 0
    last = now
  }
  return last
}

// Fills the FIFO through a descriptor of its own, which never blocks, and
// returns how many bytes it took.
function fill(fifo) {
  const fd = openSync(fifo, constants.O_WRONLY | constants.O_NONBLOCK)
  const chunk = Buffer.alloc(4096)
  let bytes = 0
  try {
    for (;;) bytes += writeSync(fd, chunk)
  } catch (e) {
    if (e.code !== "EAGAIN") throw e
  } finally {
    closeSync(fd)
  }
  return bytes
}

async function peakOf(t, dbPath, request) {
  const fifo = join(tempDir(t), "stdout")
  assert.equal(spawnSync("mkfifo", [fifo]).status, 0)
  const reader = openSync(fifo, constants.O_RDONLY | constants.O_NONBLOCK)
  const writer = openSync(fifo, constants.O_WRONLY)
  let skip = fill(fifo)
  const child = spawn(BIN, [PROTOCOL, "run", dbPath], { env: {}, stdio: ["pipe", writer, "pipe"] })
  closeSync(writer)
  let stderr = ""
  child.stderr.on("data", (d) => { stderr += d })
  const exited = new Promise((resolve) => child.on("close", resolve))
  child.stdin.end(JSON.stringify(request))
  let anon = 0
  let hwm = 0
  const out = []
  const buffer = Buffer.alloc(64 * 1024)
  for (;;) {
    const now = await blocked(child.pid)
    if (now) {
      anon = Math.max(anon, now.anon)
      hwm = Math.max(hwm, now.hwm)
    }
    let n
    try {
      n = readSync(reader, buffer)
    } catch (e) {
      if (e.code === "EAGAIN") continue
      throw e
    }
    if (n === 0) break
    const dropped = Math.min(skip, n)
    skip -= dropped
    out.push(Buffer.from(buffer.subarray(dropped, n)))
  }
  closeSync(reader)
  const status = await exited
  const answer = answerOf({ status, stdout: Buffer.concat(out).toString("utf8"), stderr })
  return { anon, hwm, answer }
}

function item(i, body) {
  return { id: i + 1, by: "widget", op: "item.add", at: T0, args: { type: "note", title: `Item ${i} café`, body } }
}

const BODY = "Ação e texto ".repeat(20).slice(0, 200)

function withItems(t, count) {
  const path = newDb(t)
  for (let start = 0; start < count; start += 250) {
    const res = call(path, { writes: Array.from({ length: 250 }, (_, i) => item(start + i, BODY)) })
    assert.ok(res.results.every((r) => r.err === undefined))
  }
  return path
}

const reload = { sync: { since: -1, views: [{ key: "v", filter: "all", query: "cafe" }] } }

test("a reload's own memory stays flat from 1 000 to 2 000 items", async (t) => {
  const small = await peakOf(t, withItems(t, 1000), reload)
  const large = await peakOf(t, withItems(t, 2000), reload)
  assert.equal(small.answer.snapshot.items.length, 1000)
  assert.equal(large.answer.snapshot.matches.v.length, 2000)
  t.diagnostic(`reload of 1 000 items: RssAnon ${small.anon} kB, VmHWM ${small.hwm} kB`)
  t.diagnostic(`reload of 2 000 items: RssAnon ${large.anon} kB, VmHWM ${large.hwm} kB`)
  assert.ok(small.anon <= ANON_LIMIT_KB && large.anon <= ANON_LIMIT_KB, `RssAnon ${small.anon} and ${large.anon} kB`)
  assert.ok(large.anon - small.anon <= ANON_SLOPE_KB, `RssAnon grew ${large.anon - small.anon} kB with 1 000 more items`)
})

test("the first spawn on a missing file, which migrates it from 0 to 5, stays under the same limit", async (t) => {
  const fresh = await peakOf(t, tempDb(t), { sync: { since: -1, views: [] } })
  assert.equal(fresh.answer.snapshot.items.length, 0)
  t.diagnostic(`new database: RssAnon ${fresh.anon} kB, VmHWM ${fresh.hwm} kB`)
  assert.ok(fresh.anon <= ANON_LIMIT_KB, `RssAnon ${fresh.anon} kB`)
})

test("a write of a body near 1 MiB, with the snapshot after it, stays under its limit", async (t) => {
  const path = withItems(t, 1000)
  // Accents and newlines, which JSON escapes, as a long note has them, up to 1 KiB under the cap.
  const unit = "Ação e texto\n"
  const body = unit.repeat(Math.floor(((1 << 20) - 1024) / Buffer.byteLength(JSON.stringify(unit).slice(1, -1))))
  const request = { writes: [item(1000, body)], sync: { since: -1, views: [] } }
  assert.ok(Buffer.byteLength(JSON.stringify(request)) > (1 << 20) - 1024 && Buffer.byteLength(JSON.stringify(request)) <= 1 << 20)
  const big = await peakOf(t, path, request)
  assert.deepEqual(big.answer.results, [{ id: 1001, value: 1001 }])
  assert.equal(big.answer.snapshot.items[0].body, body)
  t.diagnostic(`write of ${Buffer.byteLength(body)} bytes: RssAnon ${big.anon} kB, VmHWM ${big.hwm} kB`)
  assert.ok(big.anon <= WRITE_ANON_LIMIT_KB, `RssAnon ${big.anon} kB`)
})
