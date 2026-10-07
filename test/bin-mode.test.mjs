// The notes are the user's alone: the database, its backup and the files
// SQLite keeps beside it are 0600, in a folder other users of the machine can list.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { chmodSync, readdirSync, statSync } from "node:fs"
import { dirname, join } from "node:path"
import { cli, newDb, run, seeded, sync, v0Db } from "./lib/bin-fixture.mjs"

const mode = (path) => (statSync(path).mode & 0o777).toString(8)

// A sqlite3 process with the file open, so the -wal and -shm a write makes
// outlive the binary, which would delete them as the last connection.
async function holdOpen(t, dbPath) {
  const child = spawn("sqlite3", ["-init", "/dev/null", dbPath], { stdio: ["pipe", "pipe", "pipe"] })
  t.after(() => child.kill())
  const opened = new Promise((resolve, reject) => {
    let out = ""
    child.stdout.on("data", (d) => {
      out += d
      if (out.includes("open")) resolve()
    })
    child.on("exit", (code) => reject(new Error("sqlite3 exited " + code)))
  })
  child.stdin.write("SELECT count(*) FROM items;\n.print open\n")
  await opened
}

test("a database the binary creates is 0600", (t) => {
  assert.equal(mode(newDb(t)), "600")
})

test("a database another tool left 0644 is 0600 after one read, with the same owner", (t) => {
  const path = v0Db(t)
  chmodSync(path, 0o644)
  const owner = statSync(path).uid
  sync(path)
  assert.equal(mode(path), "600")
  assert.equal(statSync(path).uid, owner)
})

test("the -wal and -shm of a 0644 WAL database the binary has read are 0600", async (t) => {
  const path = v0Db(t)
  cli(path, "PRAGMA journal_mode = WAL")
  chmodSync(path, 0o644)
  sync(path)
  await holdOpen(t, path)
  assert.equal(run(path, "item.add", { type: "note", title: "in the WAL" }).err, undefined)
  const dir = dirname(path)
  assert.deepEqual(readdirSync(dir).filter((f) => f.startsWith("scratchpad.db-")).sort(), ["scratchpad.db-shm", "scratchpad.db-wal"])
  assert.deepEqual([path, path + "-wal", path + "-shm"].map(mode), ["600", "600", "600"])
})

test("a backup is 0600, and so is the copy it replaces the same day", (t) => {
  const path = seeded(t)
  const copy = join(dirname(path), "scratchpad-2026-10-07.db")
  run(path, "backup", { day: "2026-10-07" })
  assert.equal(mode(copy), "600")
  chmodSync(copy, 0o644)
  run(path, "backup", { day: "2026-10-07" })
  assert.equal(mode(copy), "600")
})
