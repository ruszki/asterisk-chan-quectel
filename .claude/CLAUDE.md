# asterisk-chan-quectel — project guide

Asterisk channel driver for Quectel / SimCOM GSM–LTE modems. C99, CMake, ~20k lines in `src/`.
A fork of [`RoEdAl/asterisk-chan-quectel`](https://github.com/RoEdAl/asterisk-chan-quectel).

**Goal of this fork: make the driver work with Asterisk 22.** Upstream targets Asterisk 20 and
older (`README.md` still says "minimal supported Asterisk version is 16").

Reference Asterisk sources are available on this machine and should be consulted rather than
guessed at:

* Asterisk **20.21.0** source tree — an unmodified official release tarball, unconfigured
* Asterisk **22.11.0** source tree — likewise

Both are pinned releases, byte-identical to `asterisk-NN.M.P.tar.gz` as published upstream. That
identity is the point: it is what makes `diff` against them a trustworthy answer to an API
question, so **never run `./configure` or `make` inside them** — configure a copy instead
(`tools/configure-asterisk-22.sh`). Being pinned, they can lag upstream's `20` / `22` dev branches.

**There are no installed Asterisk headers on this machine** — no `/usr/include/asterisk`, no
`asterisk.pc`, no `asterisk` daemon. This matches the Raspberry Pi target, where Debian 13 ships
no `asterisk` package at all. The source tree is the only header source; see §1.

`README.md` is a changes-relative-to-upstream document (dialplan surface, config options, CLI
commands). Read it for user-facing behaviour; it is not a build or architecture doc.

---

## 1. Build & verify loop

**There is no CI in this fork.** The upstream `.github/` tree (GitHub Actions workflows, composite
actions, dependabot) has been deleted deliberately — do not re-add it or any other CI integration.
Everything below runs locally; building, testing and formatting are all verified by hand.

### Two things will bite on the first attempt

**(a) `cmake --preset` fails because there are no git tags.**
`CMakeLists.txt:48-69` runs `git describe --abbrev=6 --dirty --match "v*" --long --tags` and
hard-fails with `Git - unable to describe` if it returns nothing. This clone has zero tags and
generally no network to fetch them. Create a local one in the release format
(`make-release-tag.cmake` uses `vYYYY.MM.DD`):

```sh
git describe --abbrev=6 --dirty --match "v*" --long --tags   # check first
git tag v2026.08.30                                          # only if the above fails
```

**(b) There are no Asterisk headers to find, and `ASTERISK_VERSION_NUM` silently defaults to
`180000`.** Configure now dies first on the headers:

```
-- Looking for asterisk.h - not found
CMake Error at CMakeLists.txt:210 (MESSAGE):
  Asterisk header not found.
```

Pointing `AST_HEADER_DIR` at an *unconfigured* reference tree fails at the **same** line, because
`asterisk.h:21` includes the not-yet-generated `asterisk/autoconfig.h`; only
`build/CMakeFiles/CMakeConfigureLog.yaml` says so. Fix by configuring a copy of the tree first —
see "Finding the Asterisk headers" below.

Past that, `cmake/asterisk-version-num.cmake` resolves the version as: cached cache-var →
`pkg-config asterisk version_number` → hardcoded `180000`. There is **no `asterisk.pc` installed
here**, so it lands on the default. Always pass it explicitly: `220000`. It is never derived from
the headers being compiled against, so a build can be mislabelled without any warning. It only
affects packaging metadata (see §4).

**(c) Nothing configures without a *configured* Asterisk tree.** Do this once, before anything
else; it prints the `AST_HEADER_DIR` to use (see `CLAUDE.local.md` for the paths on this machine):

```sh
AST_INC=$(tools/configure-asterisk-22.sh <asterisk-22-tree>)   # configures <tree>-configured
```

### The blessed sequence

The reproducible-build sequence. Run from the repo root.

```sh
./get-source-date-epoch.sh > .env                      # fails on a dirty tree unless PRESET is set
./get-build-flags.sh deb > CMakeUserPresets.json       # needs jq + dpkg-dev; adds BUILD_TESTING=ON
./dotenv.sh .env cmake -P make-build-dir.cmake deb 220000
./dotenv.sh .env cmake -P build-chan-quectel.cmake deb
ctest --preset deb
```

Quick local variant, no reproducible-build wrapper:

```sh
cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/usr -DASTERISK_VERSION_NUM=220000 -DAST_HEADER_DIR="$AST_INC"
cmake -P build-chan-quectel.cmake default
```

`CMAKE_INSTALL_PREFIX` has to be right at **configure** time: `quectel.conf` installs to the
absolute `${CMAKE_INSTALL_FULL_SYSCONFDIR}/asterisk` (`src/CMakeLists.txt:60-64`), so a later
`cmake --install --prefix=/usr` leaves it under `/usr/local/etc` and the module then fails to load.

`make-build-dir.cmake` passes no `AST_HEADER_DIR`, so use the plain `cmake -S/-B` form above until
a preset seeds it. **`jq`, `ninja`, `lintian` and `clang-format` are not installed on this dev
box**, so the `deb`/`rpi` preset path (`get-build-flags.sh` needs `jq`) and the packaging and
formatting targets only run on the Pi.

Other `#!/usr/bin/cmake -P` driver scripts at the root: `install-chan-quectel.cmake [arm|arm64]`,
`make-package.cmake [arm|arm64]`, `format-chan-quectel.cmake`, `make-release-tag.cmake`,
`configure-openwrt-makefile.cmake`, `install-openwrt-makefile.cmake`.

### Where things land

- Build dir: `build/` (`binaryDir` in `CMakePresets.json`). Packages: `package/`. OpenWRT staging: `install/`.
- Module: `build/src/chan_quectel.so` — a SHARED lib with `PREFIX ""` and
  `LIBRARY_OUTPUT_NAME chan_quectel` (`src/CMakeLists.txt:28-32`). Installs to
  `lib/<arch-triplet>/asterisk/modules` when `CMAKE_LIBRARY_ARCHITECTURE` is set, else
  `${CMAKE_INSTALL_LIBDIR}/asterisk/modules`. `quectel.conf` → `${sysconfdir}/asterisk`.
- Generated headers: `build/include/config.h` (from `config.h.in`) and `build/include/ptime-config.h`
  (from `src/ptime-config.h.in`).

### Finding the Asterisk headers

`ScanAsteriskHeadersDirectory()` in `cmake/asterisk-headers.cmake` accepts either form:

- a **directory** containing `asterisk.h` + `asterisk/` — pass it as `-DAST_HEADER_DIR=…`;
- an **`asterisk-headers.tar[.gz]` archive**, which is extracted into `build/include`. If
  `AST_HEADER_DIR` is unset, the source root is scanned for such an archive; otherwise system
  includes are used — and there are none here. Build one with `./asterisk-headers.sh <dir>`; its
  `/usr/include` default no longer resolves, so the argument is now mandatory, and `<dir>` must be
  a **configured** tree's `include/` or the archive reproduces the failure below.

Either way the directory must be *configured*. The reference trees for Asterisk 20 and 22 are
**not** — they have no `asterisk/autoconfig.h` and no `asterisk/buildopts.h` — so pointing
`AST_HEADER_DIR` at one directly fails at `CMakeLists.txt:208-211` with `Asterisk header not
found.` (the `FIND_PATH(… NAMES buildopts.h … REQUIRED)` at `:214` is never reached). They are for
reading and diffing, not building.

To get headers, configure a **copy**, never the reference tree itself:

```sh
tools/configure-asterisk-22.sh <src-tree> [<dest-tree>]   # dest defaults to <src-tree>-configured
```

It refuses a tree whose `.version` is not `22.*`, runs `./configure` with the module list corrected
for 22, then `make include/asterisk/buildopts.h`, and prints `<dest-tree>/include`. Build the
daemon from that same copy on the Pi so its `AST_BUILDOPT_SUM` matches the module's by
construction.

Env vars: `FORCE=1` reconfigures an existing destination (a re-run is otherwise a no-op),
`AST_DOWNLOAD_CACHE=<dir>` makes `./configure` work offline, `AST_CODEC_ARGS` overrides the codec
group, **`AST_PROFILE=headers|daemon`** picks between the lean header tree (default) and one that
also yields a usable PBX — XML docs, English core sounds, music-on-hold, `format_gsm` — and
**`AST_LIBDIR=<triplet>`** sets `--libdir=/usr/lib/<triplet>` (autodetected) so Asterisk's
`astmoddir` matches where CMake installs the module. Both profiles pin
`MENUSELECT_CFLAGS=OPTIONAL_API`, so `buildopts.h` is byte-identical between them:
`AST_BUILDOPT_SUM` is a function of the option set, not of the host or the profile. See
`plan.md` Part E.

### Build options

Root `CMakeLists.txt:123-139`. Defaults in bold.

| Option | Effect |
| --- | --- |
| `ASTERISK_VERSION_NUM` | packaging only; see §4 |
| `AST_HEADER_DIR` | Asterisk headers directory or archive |
| `BUILD_CHAN_QUECTEL_BINARY` (**ON**) | build the module |
| `BUILD_OPENWRT_MAKEFILE` (**OFF**) | generate the OpenWRT feed Makefile instead |
| `WITH_APPLICATIONS` (**ON**) | `QUECTEL_STATUS`, `QUECTEL_STATUS_EX`, `QUECTEL_SEND_SMS`, `QUECTEL_SEND_USSD` |
| `WITH_MSG_TECH` (**ON**) | `MessageSend(mobile:…)` support |
| `PTIME_USE_DEFAULT` (**ON**) | use `ast_format_get_default_ms()` instead of `PTIME_CAPTURE` (20 ms) |
| `ICONV_CONST` (**OFF**) | `iconv()` takes a `const` input buffer |
| `BUILD_TESTING` (**OFF**, ON in the `deb`/`rpi`/`rpm` presets) | enable the ctest suite |
| `CHECK_SOURCE_DATE_EPOCH` (**OFF**) | reproducible-build check target |

Dependencies: Threads, ALSA ≥ 1.1.2, SQLite3 ≥ 3.6.5, Iconv, plus Asterisk headers. On Debian:
`libasound2-dev libsqlite3-dev build-essential dpkg-dev jq`. There is **no `asterisk-dev` package
to install** — Debian 13 ships no `asterisk` at all, and it is uninstalled on this dev box — so the
headers always come from a configured Asterisk source tree (see above).
Compiled with `-Wall`, `_GNU_SOURCE`, `HAVE_CONFIG_H`,
`AST_MODULE_SELF_SYM=__internal_chan_quectel_self`, PIC, hidden visibility.

### Tests

`ctest` only runs when building from a git checkout with `BUILD_TESTING=ON`
(`src/CMakeLists.txt:66-122`). All tests inspect the built `.so`; none exercise driver logic:
`Load library`, `Check library dependencies`, `Check comment section`,
`Check architecture-specific metadata` (cross-compile only, so a native build runs **four**), and
**`Check AST_BUILDOPT_SUM`**. That last one only proves *self*-consistency — it greps the module
for the sum that came from the headers it compiled against, so it cannot detect a mismatch with an
installed daemon; compare against the daemon's own binary for that (`plan.md` Part E.5 step 12).
A mismatch is exactly what makes Asterisk refuse to load a module at runtime.

`test/parse.c`, `test/gen.c`, `test/test1.c` are legacy standalone programs, **not** wired into
CMake or ctest. `test/asterisk/AST_BUILDOPT_SUM.c` *is* used, by `ShowAstBuildOptSum()`.

### Formatting

`clang-format` **18 exactly** (`ClangFormatFindAndCheck(18)` at `CMakeLists.txt:97`). If it is
missing, CMake only warns and skips the formatting targets, so formatting silently goes unchecked —
run the check target yourself before committing.

```sh
cmake -P format-chan-quectel.cmake                 # or: cmake --build build --target asterisk-chan-quectel-code-formatter
cmake --build build --target asterisk-chan-quectel-code-formatting-check
```

---

## 2. Architecture

### Object model

`public_state_t gpublic` (`src/chan_quectel.h`) — an `AST_RWLIST_HEAD` of devices, the
`chan-quectel` threadpool, the device-manager thread and its eventfd, and global config.

`struct pvt` — one per configured device. Holds `ast_mutex_t lock`, the AT queue, the list of
`struct cpvt` channels plus a `sys_chan` pseudo-channel, data/audio fds, ALSA handles, the write
mixbuffer, string fields, `pvt_state_t state` / `pvt_stat_t stat` / `pvt_config_t settings`, and
`current_state` / `desired_state` / `restart_time`.

`struct cpvt` (`src/cpvt.h`) — one per active call: `call_state_t`, `call_flag_t`, read pipe,
mixstream, and an embedded `struct ast_frame`.

Accessors are macros: `PVT_ID(pvt)`, `PVT_STATE(pvt, f)`, `PVT_STAT(pvt, f)`, `CONF_UNIQ(pvt, f)`,
`CONF_SHARED(pvt, f)`, `CPVT_TEST_FLAG(...)`.

### Threads

1. **Device manager thread** — `dev_manager_threadproc()` in `chan_quectel.c`. Opens/closes devices
   and applies desired-state changes. Woken through an eventfd (`src/eventfd.c`).
2. **Monitor thread, one per device** — `src/monitor_thread.c`. Owns the read loop on the data TTY:
   `at_wait` → `at_read` into a ring buffer → `at_read_result_iov` splits complete responses →
   pushes `at_response_taskproc` onto the device's taskprocessor. Also drives pings/timeouts,
   expired-report purging, and ALSA/TTY health checks.
3. **Threadpool + serializers** — one `ast_taskprocessor` per device (`chan-quectel/<dev>`) via
   `ast_threadpool_serializer`. Response parsing and most state mutation run there, keeping the
   reader thread free. Inspect at runtime with `core show taskprocessors like chan-quectel`.

Work that needs `pvt->lock` from a taskprocessor goes through
`PVT_TASKPROC_TRYLOCK_AND_EXECUTE(pvt, fn)` / `PVT_TASKPROC_LOCK_AND_EXECUTE(pvt, fn)`
(`chan_quectel.h:260,267`), which also name the task for debugging.

### AT command/response round trip

```
at_enqueue_*()          at_command.c   build one or more at_queue_cmd_t
  → at_queue_insert*()  at_queue.c     wrap into an at_queue_task_t, push onto pvt->at_queue
  → at_queue_run()      at_queue.c     write the head command to pvt->data_fd        →
  … modem …
  → at_read*()          at_read.c      monitor thread reads, splits into responses   ←
  → at_str2res()        at_response.c  text → at_res_t
  → at_response()       at_response.c  dispatch to at_response_<x>(), correlate with the head task
  → at_queue_handle_result()           pop the completed command                     ↳
```

Debug logs use Unicode arrows: `↵` queued, `→` written, `←` response, `✓` OK, `↳` removed.

Call handling is notification-driven: Quectel `+QIND: "ccinfo"` (default) or `^DSCI` (`dsci=on`),
SimCOM `+CLCC`. Handlers map these to `cpvt_change_state()`, creating channels via `channel_new()`
and `start_pbx()`.

### Audio

Two paths in `src/channel.c`. **TTY mode** reads/writes the audio serial port with ring and mix
buffers, paced by an `ast_timer`. **UAC mode** uses ALSA capture/playback (`src/pcm.c`) with
`snd_pcm_link`. Format from `pvt_get_audio_format()`: `slin48` for `uac=ext`, else `slin16` when
`slin16=yes` on SimCOM, else `slin`. `mixbuffer.c` only multiplexes when `multiparty` is on
(it is off by default, and multiparty calls are actively rejected).

The multiparty branch at `channel.c:661-681` calls `ast_frame_adjust_volume()` with a **positive**
stream count where its comment intends a division — a known latent bug, deliberately left alone
because `multiparty` is off; see the `ast_frame_adjust_volume()` rule in §3 and `plan.md` §D.5.

### SMS

Inbound: `+CMT` / `+CMTI` / `+CMGR` / `+CMGL` / `+CDS` / `+CDSI` → `at_parse.c` → `pdu.c` TPDU parse
→ `char_conv.c` (UCS-2 / GSM7) → `smsdb.c` multipart reassembly → `channel_start_local_json()`
launches the `sms` extension with a JSON `SMS` variable.
Outbound: `send_sms()` (`helpers.c`) → `at_enqueue_sms()` builds multipart PDUs
(`pdu_build_mult`) → `smsdb_outgoing_*` tracks parts and delivery reports →
`channel_start_local_report()` fires the `report` extension.

### `src/` file map

| File | Responsibility |
| --- | --- |
| `chan_quectel.c/.h` | module entry (`load_module`/`unload_module`/`reload_module`, `AST_MODULE_INFO` at `:1577`), `struct pvt`, device manager thread, device create/destroy/restate, pvt lookup, threadpool |
| `channel.c/.h` | `struct ast_channel_tech channel_tech` (type `"Quectel"`, `:1210`); request/call/hangup/answer/read/write/indicate/fixup/devicestate; TTY and UAC audio paths; `channel_start_local*()` for SMS/USSD/report |
| `cpvt.c/.h` | per-call `struct cpvt`, call state machine, `cpvt_change_state()`, frame preparation |
| `at_command.c/.h` | `AT_COMMANDS_TABLE` X-macro; all `at_enqueue_*()` builders (init sequences, dial, answer, hangup, SMS, USSD, DTMF, gains, UAC/TTY switching) |
| `at_queue.c/.h` | per-device command queue, `ATQ_CMD_*` macros/flags/timeouts, device write |
| `at_read.c/.h` | poll/read loop, response splitting via iovecs |
| `at_response.c/.h` | `AT_RESPONSES_TABLE` X-macro; `at_response()` dispatcher and ~60 handlers; call state machine; `start_pbx()` |
| `at_parse.c/.h` | pure string parsers for every URC/response |
| `monitor_thread.c/.h` | per-device monitor thread, taskprocessor serializer, timeouts, restart |
| `dc_config.c/.h` | config structures and parsing (`dc_gconfig`, `dc_sconfig`, `dc_uconfig`), defaults, `pvt_config_compare()` |
| `cli.c/.h` | all `quectel …` CLI commands, auto-aliased to `simcom …` |
| `app.c/.h` | dialplan functions/applications (`WITH_APPLICATIONS`) |
| `msg_tech.c/.h` | `ast_msg_tech` named `mobile` for `MessageSend` (`WITH_MSG_TECH`) |
| `helpers.c/.h` | device lookup + "send X to device" helpers shared by CLI/apps, gain conversion, C-escaping, registration/RSSI formatting |
| `pdu.c/.h` | SMS PDU build (incl. UDH/multipart) and TPDU parse |
| `char_conv.c/.h`, `gsm7_luts.h` | UTF-8 ↔ UCS-2, hex, GSM7 pack/unpack |
| `smsdb.c/.h` | SQLite3 store for inbound reassembly and outbound tracking, TTL purge, `VACUUM INTO` backup |
| `pcm.c/.h` | ALSA capture/playback |
| `tty.c/.h` | serial port open/close with `TIOCEXCL` + `flock` locking |
| `ringbuffer.c/.h`, `mixbuffer.c/.h` | byte ring buffer; multi-stream mixing on top of it |
| `eventfd.c/.h` | eventfd helpers (device-manager wakeups) |
| `error.c/.h` | `enum error`, `error2str()`, thread-local `chan_quectel_err` |
| `ast_config.h` | include-first shim: `<asterisk.h>` → undef `PACKAGE_*` → `<config.h>` |
| `mutils.h` | `STRLEN`, `MIN`, `enum2str`/`str2enum` |
| `memmem.c/.h` | `memmem()` fallback |

### Things that are easy to get wrong

- **New AT commands go in `AT_COMMANDS_TABLE` (`at_command.h`); new responses in
  `AT_RESPONSES_TABLE` (`at_response.h`).** These X-macros generate both the enum and the string
  table — editing one without the other silently breaks the mapping.
- **New source files must be added to `src/source-files.cmake`.** There is no glob.
- **Every `.c` starts with `#include "ast_config.h"`**, before any other Asterisk header. It
  sanitises Asterisk's leaked `PACKAGE_*` macros before pulling in the generated `config.h`.
- CLI commands are registered twice via `CLI_ALIASES(...)` / `CLI_DEF_ENTRIES(...)` (`cli.c:28,50`).
  Add both or the `simcom` alias goes missing.
- Config file name constant is `CONFIG_FILE "quectel.conf"` in `dc_config.h`. The sample at the repo
  root is the installed one; `etc/quectel.conf` is identical and `uac/quectel.conf` is the UAC
  variant. `etc/extensions.conf` documents the **old** flat `QUECTEL*` variables and is superseded
  by `README.md`.

---

## 3. Asterisk 20 vs 22 — what actually differs

**The API surface this driver uses is unchanged between Asterisk 20 and 22.** This was verified by
diffing all 28 Asterisk headers included from `src/`, and by checking every `ast_*` symbol in
`src/` against the Asterisk 22 headers. Do not assume a porting problem exists before reproducing
it.

The comparison below was re-run against the pinned releases **20.21.0** and **22.11.0** and is
unchanged. Those releases lag upstream's `20` / `22` dev branches, but across the whole `include/`
tree the dev branches differ from them in only two files, neither of which changes behaviour: a
`frame.h` doc-comment correction (see the `ast_frame_adjust_volume()` rule below) and an added
`ast_taskprocessor_is_executing()` in `taskprocessor.h`.

Of the headers this driver includes, only these differ at all, and none of the differences touch
an API used here:

| Header | Difference | Used here? |
| --- | --- | --- |
| `channel.h` | removed `ast_channel_macrocontext/macroexten/macropriority`, `ast_channel_connected_line_macro`, `ast_channel_redirecting_macro`, `struct ast_channel_monitor`, `ast_channel_monitor()`. **`struct ast_channel_tech` is byte-identical.** | no |
| `module.h` | doc comment only — `AST_MODULE_INFO`, `struct ast_module_info`, `AST_MODPRI_CHANNEL_DRIVER`, `AST_MODULE_SELF_SYM` all identical. **No module API/ABI bump.** | n/a |
| `app.h` | removed `ast_app_exec_macro`, `ast_app_run_macro`, `AST_STRING_FIELD(call_macrocontext)` | no |
| `pbx.h` | removed `ast_context_lockmacro`, `ast_context_unlockmacro` | no |
| `stasis_channels.h` | removed `ast_channel_monitor_start/stop_type`; added `ast_channel_tone_detect` | no |
| `manager.h` | `AMI_VERSION` `"9.0.0"` → `"11.0.0"` | cosmetic |
| `utils.h` | `ast_gethostbyname()` marked deprecated | no |

Identical in both: `cli.h`, `frame.h`, `format.h`, `format_cache.h`, `message.h`, `json.h`,
`config.h`, `callerid.h`, `causes.h`, `taskprocessor.h`, `threadpool.h`, `timing.h`, `strings.h`,
`stringfields.h`, `logger.h`, `lock.h`, `linkedlists.h`, `localtime.h`, `musiconhold.h`,
`compiler.h`, `astobj2.h`, and `asterisk.h` itself. Deleted in 22: `monitor.h`, `pktccops.h`
(neither is included here). No header was moved or renamed.

Corroboration from Asterisk's own drivers: the entire `chan_pjsip.c` 20→22 diff is one line
dropping `ast_channel_macrocontext()`; `chan_console.c`'s diff is comment-only. `chan_sip.c`,
`chan_alsa.c`, `chan_mgcp.c` and `chan_skinny.c` were deleted in 22.

### Rules when working on version compatibility

- **Verify against the trees, not from memory.** `diff -u ${PATH_TO_ASTERISK_20_SOURCE}/include/asterisk/X.h
  ${PATH_TO_ASTERISK_22_SOURCE}/include/asterisk/X.h` before claiming an API changed. Both trees are
  pinned release tarballs, so this only answers the question for those releases — check upstream's
  branch if something looks newer than the pin.
- **`ast_frame_adjust_volume(f, adjustment)` takes a linear gain factor, not dB.** A positive
  `adjustment` multiplies each sample by its magnitude, a negative one divides, `0` is a no-op
  (`main/frame.c`, identical in 20 and 22); `10^(dB/20)` converts. Asterisk's own header said "the
  number of dB" until a post-22.11.0 doc fix. `src/channel.c:677` gets this backwards in the
  `multiparty` path — known, unfixed, recorded in `plan.md` §D.5; do not "fix" it as a drive-by.
- **Do not introduce the removed-in-22 APIs**: anything `*_macro*`, `ast_channel_monitor*`,
  `asterisk/monitor.h`.
- **Avoid adding `#if ASTERISK_VERSION_NUM` guards.** There are currently none in `src/`, by
  deliberate choice — commit `e93ef38` ("Assume ASTERISK_VERSION_NUM >= 140000") deleted
  `src/ast_compat.h` and every remaining shim. If a guard genuinely becomes unavoidable, put it in
  `src/ast_config.h` and write it as `#if ASTERISK_VERSION_NUM >= 220000`. The macro is already
  plumbed there via `config.h.in:29`.
- **Never depend on Asterisk's `autoconfig.h` audio flags.** `HAVE_ALSA` was removed in Asterisk
  22, so an `#ifdef HAVE_ALSA` would silently disable the ALSA path. ALSA is found by
  `FIND_PACKAGE(ALSA 1.1.2 REQUIRED)` at `CMakeLists.txt:253`; keep it that way.
- **Modules are not binary-portable across majors** even though the API matches. `AST_BUILDOPT_SUM`
  gates module load; rebuild per Asterisk major. The `Check AST_BUILDOPT_SUM` ctest
  (`src/CMakeLists.txt:110`) already enforces this — do not disable it.
- `struct ast_codec` gained a `quality` field in 22. Irrelevant here (this driver defines no
  codecs, it only consumes cached `ast_format` objects), but it is the one genuine struct-layout
  break in the headers.

### Where Asterisk-22 work is still outstanding

- Phase 1 is done (`plan.md` Part E): `tools/configure-asterisk-22.sh` gained `AST_PROFILE` and
  `AST_LIBDIR`, and Part E.5 is the Raspberry Pi runbook for building and installing Asterisk
  22.11.0 and loading the module. Phases 2–6 are untouched.
- `ASTERISK_VERSION_NUM` currently affects only packaging: deb dependency `asterisk16` vs
  `asterisk` (`CMakeLists.txt:323`) and the OpenWRT package name plus `AST_HEADER_DIR`
  (`openwrt/CMakeLists.txt:18`).
- No version pin anywhere exceeds `200100`: the docker Taskfiles (`docker/*/*/Taskfile.dist.yaml`)
  top out there. There is no 21 or 22 entry.
- The `asterisk-22` branch's only `src/` change is the include-order fix in `src/dc_config.c`
  (`"ast_config.h"` first, silencing four benign `struct ast_frame`/`struct ast_str`
  parameter-list warnings from `codec.h`/`format.h`); otherwise just `plan.md`, `.claude/`,
  `tools/configure-asterisk-22.sh` and the CI deletion. **`plan.md` at the repo root is the
  migration plan**: Part A the blocker inventory, Part B the ordered action list, Part C the
  Phase 0 record, Part D the reference-tree re-baseline, Part E the Phase 1 record and the
  Raspberry Pi runbook. Read it before starting version work.
- `README.md:19` still states the minimum is Asterisk 16 and gives no upper bound.

---

## 4. Conventions

- **Formatting:** `.clang-format` at the root, clang-format 18. `ColumnLimit: 160`, `IndentWidth: 4`,
  no tabs, `BreakBeforeBraces: Linux`, `PointerAlignment: Left` (`char* p`), aligned consecutive
  assignments, `InsertBraces`, `SortIncludes` with a fixed group order
  (`"ast_*.h"` → `<asterisk.h>` → `<asterisk/*.h>` → other `<*.h>` → project headers).
  Hand-laid-out regions are fenced with `// clang-format off` / `on`.
- **Naming:** lower_snake_case, module-prefixed — `pvt_*`, `cpvt_*`, `at_enqueue_*`, `at_parse_*`,
  `at_response_*`, `at_queue_*`, `dc_*`, `smsdb_*`, `rb_*`, `mixb_*`, `pcm_*`, `tty_*`, `channel_*`,
  `cli_*`. Types are `*_t` typedefs; macros and enums are ALL_CAPS.
- **Memory / RAII:** Asterisk allocators only (`ast_calloc`, `ast_free`, `ast_strdup`, `ast_str_*`).
  `RAII_VAR(type, name, init, dtor)` is used heavily (~90 sites), along with `SCOPED_MUTEX`,
  `SCOPED_LOCK`, and the project's `SCOPED_CPVT`, `SCOPED_DB`, `SCOPED_STMT`, `SCOPED_TRANSACTION`.
  JSON is built with `ast_json_*` under `RAII_VAR(..., ast_json_unref)`.
- **Errors:** return `int` (0 = ok); detail goes in the thread-local `chan_quectel_err`
  (`src/error.h:43`) set to an `enum error`, rendered by `error2str()`. Early return with explicit
  cleanup; `goto e_cleanup` / `e_restart` in the monitor loop.
- **Logging:** `ast_log(LOG_ERROR|LOG_WARNING|LOG_NOTICE, …)`, `ast_debug(level, …)`,
  `ast_verb(level, …)`. Always prefix with the device: `[%s]` / `PVT_ID(pvt)`, plus a subsystem tag
  where useful — `[%s][DATA]`, `[%s][ALSA]`, `[%s][AUDIO][TTY]`, `[%s][SMS:%d %s]`. Raw device
  traffic must be C-escaped with `tmp_esc_str()` / `tmp_esc_nstr()` (`helpers.h`).
- **Commits:** single line, imperative, capitalised, no trailing period, ≲55 chars. Optional
  lowercase subsystem prefix and colon: `cli:`, `cmake:`, `cpack:`, `smsdb:`. AT command names
  appear verbatim (`Improve +CDSI response handler`). No ticket refs, no Conventional Commits.
- The marker comment `#/* */` before many functions is a legacy section separator — harmless, leave it.
