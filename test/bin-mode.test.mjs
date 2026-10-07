// The notes are the user's alone: the database, its backups and the files
// SQLite keeps beside it are 0600, in a folder other users of the machine can list.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { chmodSync, mkdirSync, renameSync, statSync, symlinkSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { cli, newDb, run, seeded, sync, tempDb, tempDir, v0Db } from "./lib/bin-fixture.mjs"

// The binary inherits this. A umask of 077 in the shell that runs the tests
// would make every file 0600 whatever the binary does.
process.umask(0o022)

const mode = (path) => (statSync(path).mode & 0o777).toString(8)

// A sqlite3 process with the file open, so the -wal and -shm outlive each
// binary, which would delete them as the last connection.
async function holdOpen(t, dbPath) {
  const child = spawn("sqlite3", ["-init", "/dev/null", dbPath], { stdio: ["pipe", "pipe", "pipe"] })
  t.after(() => child.kill())
  const opened = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("sqlite3 did not open the file in 10 s")), 10000)
    let out = ""
    child.stdout.on("data", (d) => {
      out += d
      if (out.includes("open")) {
        clearTimeout(timer)
        resolve()
      }
    })
    child.on("error", reject)
    child.on("exit", (code) => reject(new Error("sqlite3 exited " + code)))
  })
  child.stdin.write("SELECT count(*) FROM items;\n.print open\n")
  await opened
}

test("a database the binary creates is 0600", (t) => {
  assert.equal(mode(newDb(t)), "600")
})

test("a database reached through a link to a missing file is created 0600", (t) => {
  const path = tempDb(t)
  mkdirSync(dirname(path), { recursive: true })
  const target = join(dirname(path), "elsewhere.db")
  symlinkSync(target, path)
  sync(path)
  assert.equal(mode(target), "600")
})

for (const left of [0o644, 0o664]) {
  test(`a database another tool left ${left.toString(8)} is 0600 after one read`, (t) => {
    const path = v0Db(t)
    chmodSync(path, left)
    sync(path)
    assert.equal(mode(path), "600")
  })
}

test("a -wal and -shm left 0644 beside the database are 0600 after one read", async (t) => {
  const path = v0Db(t)
  cli(path, "PRAGMA journal_mode = WAL")
  await holdOpen(t, path)
  assert.equal(mode(path + "-wal"), "644", "sqlite3 made them under umask 022")
  assert.equal(mode(path + "-shm"), "644", "sqlite3 made them under umask 022")
  sync(path)
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

test("a backup of an earlier day and a .tmp left 0644 are 0600 after one read", (t) => {
  const path = seeded(t)
  const earlier = join(dirname(path), "scratchpad-2026-10-06.db")
  const tmp = join(dirname(path), "scratchpad-2026-10-05.db.tmp")
  cli(earlier, "CREATE TABLE t (x)")
  writeFileSync(tmp, "")
  chmodSync(earlier, 0o644)
  chmodSync(tmp, 0o644)
  sync(path)
  assert.deepEqual([earlier, tmp].map(mode), ["600", "600"])
})

test("a link named like a backup leaves the mode of the file it points to", (t) => {
  const path = seeded(t)
  const elsewhere = tempDir(t)
  const pairs = [["scratchpad-2026-10-04.db", "page.html"], ["scratchpad-2026-10-03.db.tmp", "notes.txt"]]
  for (const [name, target] of pairs) {
    writeFileSync(join(elsewhere, target), "theirs")
    chmodSync(join(elsewhere, target), 0o644)
    symlinkSync(join(elsewhere, target), join(dirname(path), name))
  }
  sync(path)
  assert.deepEqual(pairs.map(([, target]) => mode(join(elsewhere, target))), ["644", "644"])
})

test("a database that is a link to a file elsewhere is 0600 there, with its -wal and -shm", async (t) => {
  const path = v0Db(t)
  const real = join(tempDir(t), "synced", "scratchpad.db")
  mkdirSync(dirname(real))
  renameSync(path, real)
  symlinkSync(real, path)
  chmodSync(real, 0o644)
  cli(path, "PRAGMA journal_mode = WAL")
  await holdOpen(t, path)
  assert.equal(mode(real + "-wal"), "644", "sqlite3 made them beside the file the link points to")
  sync(path)
  assert.deepEqual([real, real + "-wal", real + "-shm"].map(mode), ["600", "600", "600"])
})

test("other files in the folder keep their mode", (t) => {
  const path = seeded(t)
  const others = ["other.db", "scratchpad.db.bak"].map((name) => join(dirname(path), name))
  for (const file of others) {
    writeFileSync(file, "")
    chmodSync(file, 0o644)
  }
  sync(path)
  assert.deepEqual(others.map(mode), ["644", "644"])
})
