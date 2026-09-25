# Search matches a folded copy of title and body

SQLite's `LIKE` and `lower()` only fold ASCII, so a search for `CAFÉ` missed `Café`, and the sqlite3 CLI has no ICU to fold the rest. Each item keeps a folded copy of its title and body in `search_title` and `search_body`, and `listSql` folds the query the same way before matching the copy with `LIKE`. `searchText` in `data/Db.js` folds: lower case, then the accents of the Combining Diacritical Marks block (U+0300 to U+036F) dropped through NFD, one UTF-16 unit at a time. `addSql` and `updateSql` write the copy with the item.

## Consequences

- The copy is text built in JS and quoted by `q()`, like every other value (ADR-0002). A write that changes a title or body must also write its copy, or search misses the item.
- The migration that adds the columns (`searchCopyMigration`) fills them for the items already there in SQL, through a temporary table `search_map` of every character `searchChar` changes, applied one character at a time. Folding one unit at a time is what lets the SQL match the JS on every item; folding whole strings can differ, as Node's `toLowerCase` does on a final Greek sigma.
- Characters outside the Basic Multilingual Plane are not folded, in JS or in SQL.
- Building `search_map` takes about 45 ms in Quickshell, so the entry is a function and runs only for a database below it (ADR-0011). Filling 1000 items of 1000 characters took 1.3 s on the machine it was written on, because `substr` walks the text from its start each time.
- The map comes from the JS engine's Unicode tables. The Quickshell and Node builds used when this was written give the same map. A later Unicode change to a character can leave the copies from before it folded the old way.
