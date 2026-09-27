# Changelog

All notable changes to kod. The format follows
[conventional commits](https://www.conventionalcommits.org), and each
push to `main` bumps the patch version, writes the entry, and tags the
release.

## v0.1.0 (2026-09-27)

First release.

### Feat

- **paging.** kod never loads a file. It keeps 64 page slots of 64KB
  and holds only your edits in RAM, so a buffer costs about 4MB plus
  its edits whether it is a config file or a multi-gigabyte log. Files
  past the window start a background readahead thread.
- **trees.** Every list is the same foldable tree: the file browser,
  the buffer list, the git log, search hits, diagnostics, and the
  `:tree` inspector. `Enter` folds a section and jumps a leaf. A
  location list is a tree with no children.
- **diagnostics from the outside.** `:exec` and `:exec-save` run a
  tool in a worker thread. kod links no compiler and no language
  server. A `path:row:col: message` row becomes a jump target, every
  open file it names gets a mark in the gutter, and the header counts
  the marks. Saving the file reruns the command in silence.
- **search.** `/pat/repl/flags` in a buffer, `f/` over file names,
  `b/` over open buffers, with `i` for case and `g` for all, and `n`
  and `p` to step the hits.
- **git verbs.** `:gadd`, `:gcommit`, `:gpush`, `:gpull`,
  `:gswitch`, `:gbranch`, and a foldable log with diffs.
- **undo forest.** Every edit is recorded with its payload. An edit
  after an undo branches instead of overwriting, and `:tree undo`
  shows the forest.
- **highlighting.** A fixed monokai-like theme by extension, plus
  per-row styling for every tree, so listings, git log, search hits,
  diagnostics, and the welcome and help pages all color.
- **atomic saves.** A save streams to a temp file and renames it over
  the original, so a reader sees the old file or the new one.
