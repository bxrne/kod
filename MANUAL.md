# kod manual

This manual holds every key, every command, every view, and the design notes behind them. `README.md` holds the short story.

## Start

```sh
kod            # welcome buffer
kod file.zig   # one file
kod src        # a directory as an editable buffer
kod --help     # the command table and the keys
kod --version  # the version
```

A file argument that does not exist reports the error and exits.

## Modes

| Mode | Enter | Leave |
| ---- | ----- | ----- |
| normal | always active | `i` for insert, `:` for command |
| insert | `i` | `Escape` saves and returns to normal |
| command | `:` or `/` | `Enter` submits, `Escape` cancels |

Normal mode edits save at once. There is no insert session to leave. A count prefix applies to the next motion or edit and then dies.

## Normal mode keys

| Key | Action |
| --- | ------ |
| `h` `j` `k` `l` | move one column or line |
| `4j` | move four lines; counts can be negative, as in `-4j` |
| `0` | line start |
| `$` | line end |
| `gg` | top of the file |
| `G` | bottom of the file |
| `13` then `Enter` | jump to line 13 |
| `f` | jump to the next word start |
| `F` | jump to the previous word start |
| `d` | delete lines, count lines |
| `o` | open a line below and type |
| `O` | open a line above and type |
| `c` | overwrite the next character, the one you type next |
| `r` | replace the next character, the one you type next |
| `u` | undo |
| `Ctrl+R` | redo |
| `i` | insert mode |
| `:` | command mode |
| `/` | search in the current buffer, prefilled |
| `n` | next hit |
| `p` | previous hit |
| `q` | quit |
| `Enter` | open the row under the cursor in a view, otherwise jump to a line number |
| `Escape` | drop a count prefix and a selection |

The cursor stays mid-screen and follows the file. A file never wraps a motion past either end. A view cycles instead, so `j` past the last row lands on the first.

## Selections

Shift and an arrow key starts a selection. Motions extend it. `d` deletes the range, `c` deletes it and drops into insert mode, and `r` overwrites it. `Escape` cancels the selection. Any doc switch or edit ends it.

## Insert mode keys

Type to insert. Arrows move. `Enter` inserts a newline. `Backspace` deletes. `Escape` saves the file and returns to normal mode.

## Command mode

Type the command and press `Enter`. `Up` and `Down` walk the session history. `Escape` cancels. A rejected command keeps the text and shows the reason on the right edge of the box, for example `unknown command` or `exec-save needs a file`.

## Commands

| Command | Action |
| ------- | ------ |
| `:q` `:quit` | quit |
| `:fs [path]` | open a directory as an editable buffer, empty means the parent of the current file |
| `:buf` | list and operate open buffers |
| `:git` | open the current branch log |
| `:gadd [paths]` | stage paths, empty stages all |
| `:gcommit <text>` | commit staged work |
| `:gpush` | push the current branch |
| `:gpull` | pull the current branch |
| `:gswitch <branch>` | switch branch |
| `:gbranch <name>` | create and switch to a branch |
| `:/pat/repl/flags` | regex find in the buffer |
| `:f/pat/repl/flags` | regex find over filenames |
| `:b/pat/repl/flags` | regex find over open buffers, `bl/` is an alias |
| `:help` | list every command with its keys |
| `:tree [name]` | inspect undo, search, exec, buffers, git, commands. A name opens that tree alone, as in `:tree exec` |
| `:exec [cmd]` | run a shell command into the `*exec*` tree, empty reruns the last one |
| `:exec-save <cmd>` | run it, and rerun on every save of the file, `execsave` is an alias |

## Search

The spec is `pat/repl/flags`. The replacement is optional, and an empty replacement deletes the match. Write `\/` for a slash inside the pattern. A fourth part or an unknown flag is an error.

| Flag | Meaning |
| ---- | ------- |
| `i` | case insensitive |
| `g` | every match, not the first |

| Scope | Meaning |
| ----- | ------- |
| `/` | the current buffer. The cursor lands on the first hit, and the next submit moves to the next one |
| `f/` | file names under the working directory. A replacement renames |
| `b/` | every open buffer. A replacement edits each one |

`n` and `p` step the last query. They follow hits into other buffers. A line longer than 1MB is skipped. The results tree lists at most 1000 hits, and a file walk stops at 50000 files.

`Enter` on a file result switches to the buffer that already holds the file, so a result never opens a second copy of the same path. When no buffer holds it, `Enter` opens the file. A tool reports a path relative to its own root, so a path matches an open file when either side ends with the other past a separator.

## Diagnostics

`:exec <cmd>` runs `sh -c <cmd>` in a worker thread. kod stays responsive. The command line you type is the command that runs, so pipes and redirections work.

The `*exec*` tree shows one header row plus one row per output line. Stderr comes first, then stdout, so compiler errors sit at the top. A row that reads `path:row:col: message` becomes a jump target, and a row that reads `path:row: message` jumps to the line. Every other row is log context.

`Enter` opens a diagnostic from *any* row of the tree: a hit row opens its own file, and a plain log row opens the next hit below it. The file opens when it is closed and switches when it is open. `n` and `p` walk the hits.

Every open file that the hits name gets a mark in the gutter. Errors are pink, warnings are yellow. A mark dims when the file changed after the run, so an old mark never lies. The next run clears it. The header carries the counts as `2e 1w`, so a buffer with marks never looks clean even when the marked row sits far from the camera.

`:exec-save <cmd>` runs the command and arms it for the current file. Every save of that file reruns it in silence, without a doc switch. Run it from a tree view and it arms the newest open file. Only one run is in flight at a time, and the command box says so when a second run is refused.

## Views

| View | Title | Enter | `Escape` |
| ---- | ----- | ----- | -------- |
| file | the path | moves | saves |
| directory | the path | opens the row | saves the edits to disk |
| buffers | `*bufs*` | switches to the row | applies the edits |
| git | `*git*` | folds or opens a diff | refreshes from git |
| search | `*search*` | jumps to the hit | nothing |
| diagnostics | `*exec*` | jumps to the hit | nothing |
| trees | `*tree*` and `*tree <name>*` | folds or jumps | re-renders |
| welcome, help | `*welcome*` `*help*` | nothing | nothing |

The welcome buffer shows three commands and points at `:help` for the rest. Both it and the help listing color command verbs, arguments, key groups, and the version, and nothing else.

A directory view is an editable list of its entries. A new line creates an entry, a removed line removes the entry, and an edited line renames or moves it. The rows show directories and dot files dimmer.

A buffer list is also editable. A removed line closes that doc, an edited line renames the file on disk and rehomes the doc, and a new line opens a file or a directory.

## The trees

`:tree` opens one readonly buffer with six foldable sections. Every section starts folded. `Enter` on a header folds it.

`:tree <name>` opens one tree in a buffer of its own, titled `*tree <name>*`, with the same rows, the same styling, and the same `Enter` behavior. The names are `undo`, `search`, `exec`, `buffers`, `git`, and `commands`. Each tree is one buffer per session, and the full inspector is a buffer of its own, so both stay open.

| Tree | Rows | Enter on a row |
| ---- | ---- | -------------- |
| undo | one forest per open file | folds the doc, or jumps to that node in the file |
| search | the last query and its hits | opens the file or switches to the buffer |
| exec | the command, the exit code, and the `path:row:col:` hits of the last run | opens the file at the reported line, and on the header opens the first hit |
| buffers | every open doc with its kind and cursor | switches to the doc |
| git | the branch, the counts, and the recent commits | opens the git log |
| commands | the commands you ran this session, newest first | puts the command back in the command box |

The command rows are the same list the command box walks with `Up` and `Down`. `Enter` fills the box, so you can edit the command or press `Enter` again to run it.

The exec tree carries the jumpable rows of the run, not the whole output. The whole output stays in the `*exec*` tree, where plain log rows live between the hits.

The undo forest is a real tree. Every step nests under its parent, and an edit after an undo starts a branch instead of overwriting. The indent grows with the depth, so a fork reads as a fork.

## Highlighting

The theme is a fixed monokai-like 256 color table. A file highlights by its extension. A view highlights its own rows:

| Buffer | Colors |
| ------ | ------ |
| file | the language of its own extension |
| directory, buffer list | each row names a file, so each row takes the language of its own extension, except markdown and other prose, which stay plain. Directories and dot files dim |
| git log | branch and header rows, hashes, stat graphs, patch lines |
| trees | section headers, hashes, undo op kinds, positions, and quoted payloads, and command rows |
| search and diagnostics | the `path:row:col:` positions, then the rest of the row in the language of the hit path, and a bare file row in its own language |
| welcome and help | the command verbs, their arguments, the key groups, and the version |

## Paging and saves

kod never loads a file. It keeps 64 page slots of 64KB, which is a 4MB window over the original. Only your edits live in RAM. A file above the window starts a background readahead thread that fills free slots ahead of the reader.

The original bytes never change in place. The buffer is a red-black tree of pieces that point into the original or into the add buffer. A save streams the pieces to a temp file and renames it over the original, so a reader sees the old file or the new file and never a partial one.

The undo tree records every edit, including the payload, so undo and redo do not need the disk.

## Build and test

```sh
zig build           # build zig-out/bin/kod
zig build test      # run the test suite
zig build run -- f  # build and run with a file
zig build binstall  # copy kod to ~/.local/bin
```

`build.zig` reads the version from `build.zig.zon` at comptime and passes it to the code as the `config` module. `-Dversion=x.y.z` overrides it.

## Design notes

* One piece table serves files and views. A view owns its text in memory instead of a file on disk.
* One usertree module renders every list. A location list is a tree with no children.
* A background worker owns its memory until the main loop joins it, so the main allocator is never touched from two threads.
* The page cache and the piece tree never copy file bytes. A hit costs one page read.
* The exec tree parses `path:row:col:` on its own. kod links no compiler and no language server.

## Limits

* Diagnostics need a `path:row:col:` shape. Other output is log context.
* The exec tree holds one whole run in memory, so a tool that prints a gigabyte is a bad tool for kod.
* The command history holds 128 entries in memory. kod reads no history from disk and writes none.
* The search results tree caps at 1000 hits.
