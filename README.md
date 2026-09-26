# kod

kod is a terminal editor for large files. It uses vim keys and a different core.

Two ideas define the editor.

**Paging.** kod does not load the file. It pages the original through a 4MB window and keeps only your edits in RAM. A buffer costs about 4MB plus its edits, whether it is a config file or a multi-gigabyte log.

**Trees.** Every list is the same foldable tree. The file browser, the buffer list, the git log, the search results, the diagnostics, and the state inspector all use it. A location list is a tree with no children.

Trees are also the answer to "what is kod doing". The `:tree` inspector shows the undo history of every open file, the last search, the diagnostics of the last run, the open buffers, the git log, and the commands you ran this session. Enter on a row goes there. Enter on a command row puts that command back in the command box. `:tree exec` opens one tree in a buffer of its own.

## Run

```sh
git clone git@github.com:bxrne/kod.git
cd kod
zig build run -- [file|dir]
```

Install once, then run from anywhere:

```sh
zig build binstall
kod [file|dir]
```

You need zig 0.16. kod has no dependencies.

`kod` with no argument opens the welcome buffer. `kod <dir>` opens that directory as an editable file buffer.

## Use

Three modes. Normal mode moves and edits. Insert mode types. Command mode starts with `:`.

Counts repeat a motion, so `4j` moves down four lines. Leaving insert mode saves the file. A normal mode edit saves at once.

| Command             | Action                                       |
| ------------------- | -------------------------------------------- |
| `:fs [path]`        | open a directory as an editable buffer       |
| `:buf`              | list and operate open buffers                |
| `:git`              | open branch, status, and log                 |
| `:gadd [paths]`     | stage paths, empty stages all                |
| `:gcommit <text>`   | commit staged work                           |
| `:gpush`            | push the current branch                      |
| `:gpull`            | pull the current branch                      |
| `:gswitch <branch>` | switch branch                                |
| `:gbranch <name>`   | create and switch to a branch                |
| `:/pat/repl/flags`  | regex find and replace in the buffer         |
| `:f/pat/repl/flags` | regex find over filenames                    |
| `:b/pat/repl/flags` | regex find over open buffers                 |
| `:tree [name]`      | inspect undo, search, exec, buffers, git, commands |
| `:exec [cmd]`       | run a shell command into the `*exec*` tree   |
| `:exec-save <cmd>`  | run it, and rerun on every save of the file  |
| `:help`             | list every command with its keys             |
| `:q`                | quit                                         |

Tools report from the outside. No language server runs inside kod. A command such as `:exec-save zig build` runs in a worker thread, and kod keeps only the positions. A `path:row:col: message` row becomes a jump target, every open file it names gets a mark in the gutter, and the header counts the marks. Saving the file reruns the command in silence, and `:tree exec` shows the last run.

## Learn more

`MANUAL.md` holds the keys, the views, search, diagnostics, the inspector, and the design notes.

## Build

```sh
zig build           # build zig-out/bin/kod
zig build test      # run the test suite
zig build run -- f  # build and run
zig build binstall  # copy kod to ~/.local/bin
```

The version comes from `build.zig.zon` and reaches `kod --version`, the welcome buffer, and both help texts. Pass `-Dversion=x.y.z` to override it.

## Releases

Commits follow conventional commits. Each push to `main` runs commitizen, which bumps the version, writes the changelog, and tags the commit. Tags build release binaries for Linux and macOS on the releases page.
