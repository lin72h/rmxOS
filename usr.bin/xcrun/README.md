# Preview developer-tools launcher

`xcrun.zig` and `xcode-select.zig` are Zig 0.16.0 source artifacts for later
rmxOS integration. Workspace builds and isolated checks install nothing and
do not change the host's developer selection. `developer_paths.zig` holds the
shared production paths; `selection.zig` supplies both tools' query resolution
and directory validation.

From the canonical port repo, build with packaged `/usr/local/bin/zig`:

```zsh
scripts/build-xcrun.zsh
scripts/build-xcode-select.zsh
```

The explicit compiler command is:

```zsh
/usr/local/bin/zig build-exe -O ReleaseSafe -lc \
  --dep developer_paths -Mroot=rx/developer-tools/xcrun.zig \
  -Mdeveloper_paths=rx/developer-tools/developer_paths.zig \
  --cache-dir .work/op144/cache --global-cache-dir .work/op144/global-cache \
  -femit-bin=.work/op144/production/xcrun
```

The build runner sets `TMPDIR` under `.work/op144/` and clears injected include/
library paths. The xcode-select build uses the same flags with
`-Mroot=rx/developer-tools/xcode-select.zig`, caches/TMPDIR under `.work/op146/`,
and `-femit-bin=.work/op146/production/xcode-select`. Both executables link
base libraries and require neither Swift nor a staged rmxOS root. Run isolated
integration checks with:

```zsh
RX_TEST_WORK_ROOT="$PWD/.work/op146/xcrun-regression" scripts/test-xcrun.zsh
scripts/test-xcode-select.zsh
```

The Elixir check compiles fixtures with a replacement `developer_paths` module.
The xcrun regression uses the integration harness's `RX_TEST_WORK_ROOT` for
artifacts only (its default remains `.work/op144/`). The selector suite reuses
one compiled xcode-select/xcrun pair and one fixture executable, all under
`.work/op146/`. Both suites substitute selection paths only at compile time;
production path defaults are never redirected by a test environment variable.

## xcrun contract

- For tool operations, a nonempty `DEVELOPER_DIR` wins. Otherwise read the
  target of `/var/db/xcode_select_link`. Only an absent selection link permits
  `/Library/Developer/CommandLineTools` as the default. Empty `DEVELOPER_DIR`
  is ignored. Relative, dangling, nonexistent and nondirectory selections are
  errors; an invalid higher-priority choice never falls through.
- Tools resolve to `<developer directory>/usr/bin/<tool>`. The name must be a
  nonempty basename, excluding `.`/`..` and leading `-`; `/` is rejected.
  Symlinked developer directories/tools are accepted when their resolved
  targets are valid. Tools must resolve to executable regular files. PATH is
  never searched.
- `xcrun TOOL [args...]` and `xcrun --run TOOL [args...]` replace the launcher
  with that full executable path using `execv`, retaining the environment,
  remaining argument boundaries and child exit status. The child's `argv[0]`
  is the full tool path.
- `xcrun --find TOOL` prints that full path followed by a newline, without
  executing it; extra arguments are rejected.
- `xcrun --show-sdk-path` prints `/` followed by a newline; `xcrun --help`
  prints usage. These two queries do not require or read a selection. Neither
  accepts extra arguments.
- Invocation basenames `swift`, `swiftc`, `swift-build`, `swift-test`,
  `swift-run`, `swift-package`, and `sourcekit-lsp` dispatch to that selected
  tool, forwarding all remaining arguments, including option-looking ones.
  The integration tests use actual hard links. No clang/cc/lldb wrapper or
  host link is created.
- Launcher selection/tool/exec failures return 1 and explain that developer
  tools must be installed or selected. Directory/tool failures name the chosen
  directory; unreadable/non-link selector errors name the selector path.
  Syntax errors return 2. After successful exec, the tool controls the status.

Only the exact forms above are parsed. Short options, `--find=...`, `--run=...`,
`--`, `--sdk`, `--toolchain`, `--show-sdk-version`, cache/logging/verbosity flags
and combined/reordered xcrun option forms are not implemented. Once TOOL is
parsed (or an invocation alias is recognized), remaining options belong to the
tool and are forwarded. Selection operations, SDK discovery, version lookup,
PATH fallback and the complete Apple option set are outside this preview.

## xcode-select contract

- `--print-path` / `-p` print the effective absolute developer directory using
  exactly xcrun's shared precedence and validation. Invalid selections fail
  without falling through. Queries never write the selector.
- `--switch DIR` / `-s DIR` require an absolute existing directory. They ignore
  `DEVELOPER_DIR` when storing the new target. A randomly named new symlink is
  staged in the selector's existing parent, then renamed over the selector
  atomically. Creation, checks, cleanup and rename use an open parent directory
  descriptor. An existing selector must be a symlink; regular files and
  directories are rejected and preserved. Dangling symlinks can be replaced.
  The parent must already exist and permit writes; no directories or privilege
  elevation are created. Failure paths attempt to remove their staged link.
- `--reset` / `-r` remove only the selection symlink, including a dangling one.
  An absent selector (including an absent parent) succeeds. Regular files and
  directories fail and remain unchanged. Without `DEVELOPER_DIR`, the next
  query uses the default directory and validates it normally.
- `--help` / `-h` print usage. These are the complete supported forms. Missing/
  extra operands, combined/equals options, version options and `--install` are
  rejected with exit 2. Operational errors return 1; success returns 0.

Installation/download UI and the remaining Apple option set are unimplemented.
For rmxOS handoff, take both entry sources, `selection.zig`, and
`developer_paths.zig` together. Production defaults remain
`/var/db/xcode_select_link` and `/Library/Developer/CommandLineTools`. Building
does not authorize running production switch/reset commands; this workspace
qualification mutates only the compiled isolated-path variants.
