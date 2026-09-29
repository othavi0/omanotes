# Write one result line per write

In protocol 1, `omanotes-db` wrote the results of a request as one line, `{"results":[...]}`, after the last write of the request (ADR-0018). The Lane kills a spawn that runs past its limit, 30 s and 5 s more for each write it carries. When the kill came during write k+1, writes 1 to k were committed, but no line had gone out. `Db.reply` read the answer as a crash, and the Store answered every write of the request `crash`. An add answered `crash` gives its text back to the editor as a draft, and saving the draft again added the note a second time (issue #57). `test/panel.sh` shows it. A request carries an add and a status change, and `test/lib/stall-journal.c` holds the second write on the disk until the Lane kills the request. With protocol 1 the note is in the file, the editor shows it as a draft (`draft:true`), and a second save makes the count 2.

Protocol 2 writes each result as soon as its write ends. `Protocol.Current` is 2 and `Min` is 1 in `db/Wire.cs`, and `PROTOCOL` is 2 in `data/Db.js`.

- stdout is one line per write, in request order, then the snapshot line when the request asked for one. Each line is the result object of protocol 1, `{"id","value"}` or `{"id","err","detail"}`. The binary writes each line with one write(2) of a buffer of its own, right after `Writes.Run` or `Writes.Refuse` returns and before the next write starts. The snapshot is unchanged. In a read, a request with no writes, the snapshot is line 1. The exit codes are the same: 0, 3, and 1, 64 or 70.
- `Db.reply(writes, exitCode, crashed, stdout, stderr)` takes the number of writes the request carried, which the Lane reads from the Store's request (`sent.writes.length`). Only a line ended by "\n" is whole. The first `writes` whole lines are the results, read up to the first line that is not an object with a numeric `id`.
- A request with writes and no whole result line fails whole, as in protocol 1: the last line of stderr on exit 1, 64 or 70, otherwise `crash`.
- A request with fewer results than writes is `ok` with those results, no snapshot, and the failure as `syncErr`: the signal, or the last line of stderr. The Store answers each write with no result `crash` ("no result"). It lands every write's result in order, then tells the failure and asks again, as for any failed read.
- With every result, exit 0 reads the next whole line as the snapshot, and a snapshot line that does not parse is `crash` ("unreadable answer"). Exit 3 takes `syncErr` from the last line of stderr. Any other exit or a signal is the `syncErr`.
- A read with exit 0 needs its snapshot line. A read with exit 3 is `ok` with `syncErr`. Any other read that ends another way fails.
- Protocol 1 keeps its bytes: one `{"results":[...]}` line after every write, then the snapshot. Between the merge of an update and the restart of the shell, the QML of before runs against the new binary (ADR-0017). Protocol 1 has shipped, so `Min = Current - 1` is needed now. `Speaks` returns the protocol that argv[1] names, and `Run` writes the results in that protocol's shape. The request, the snapshot and the alarm columns are the same in both protocols.

## Considered options

- One results line, written through `FdWriter` as each write ends. `FdWriter` holds 64 KiB before it writes, so the line would wait for the buffer. A cut `{"results":[` array is also not JSON, so the reader would parse a prefix by hand.
- A longer limit in the Lane. The kill is there because a spawn stuck on a disk holds the queue forever (ADR-0018). A longer limit makes the kill rarer, and a kill during a later write still loses the results before it.

## Consequences

- A kill between a write's COMMIT and the write(2) of its line still reports a committed write as `crash`, and an add killed in that window still comes back to the editor as a draft. The window is not closed. It holds the end of the result object and one write(2) of a line under 1 KiB to a pipe (inferred from `WriteResultLines` in `db/Program.cs`; not measured).
- The QML of before speaks protocol 1 until the restart, so #57 stays open for it until then.
- On exit 70 the result lines of the writes that ended can come before the failure. For example, a write(2) to a reader that went away throws, and `Main` answers `internal`. In protocol 1 there was no line 1 then.
- The watcher's read can list the row of an add before the add's result lands, when a later write of the same request holds the request. No `itemsUpdated` comes after the result then, and the row selected before stayed selected. `ItemsTab.onAdded` now selects the new row at once when the list already shows it. `test/panel.sh` showed the order: the list grew to the new row, then `added` came, and the editor kept the row selected before.
- The log of the killed request has two lines: the write the kill cut off ("the database helper stopped without an answer") and the read failure ("read failed: the database helper stopped without an answer").
- `test/lib/stub-db.sh` puts back the "\n" that `$(...)` drops in `hold-reads`, since a snapshot line with no "\n" is not whole.

## Gates

Each gate is a test that failed with its defect planted and passes without it.

- A request killed part way keeps the note it committed out of the editor, and a second save does not add the note twice (`test/panel.sh`, with `test/lib/stall-journal.c`). It failed with protocol 1 (`draft:true`, a count of 2). With protocol 2 alone, it failed on the editor, which kept the row selected before, until `ItemsTab.onAdded` selected a listed row.
- The real binary, with `test/lib/stall-journal.c` preloaded and a request of two `item.add`, has written `{"id":1,"value":1}` and its "\n" once the first note is in the file and the second write is held. The test then kills it (`test/bin-concurrency.test.mjs`). It failed with argv[1] set to 1: no line within 5 s.
- `Db.reply` keeps each whole result line of a killed request, stops at a line that is not a result, does not count a last line with no "\n", and reads a request with no writes (`test/db.test.mjs`). Four of its tests failed when a last line with no "\n" counted as whole.

## Tests

- Protocol 1 gets one results line whose items are the protocol 2 lines, and the same snapshot line (`test/bin-protocol.test.mjs`).
- The committed binary speaks `[PROTOCOL - 1, PROTOCOL]` of `data/Db.js` (`test/db.test.mjs`).
- `answerOf` in `test/lib/bin-fixture.mjs` reads the protocol 2 shape for every `bin-*` test, and on exit 0 it requires every line to be whole.
