# Migrating asterisk-chan-quectel to Asterisk 22 on 64-bit Raspberry Pi OS

## Context

This fork exists to make `chan_quectel` work with Asterisk 22. The `asterisk-22` branch currently
contains **zero porting work** — `git diff --stat master asterisk-22` is only `.claude/CLAUDE.md`,
the CI deletion, and a `.gitignore` line.

The migration was investigated by diffing every Asterisk header the driver includes between
`/home/quectel/asterisk-20` (20.21.0) and `/home/quectel/asterisk-22` (22.11.0), auditing all 310
`ast_*`/`AST_*` identifiers used in `src/` against the 22 headers, and syntax-compiling the driver
against the 22.11.0 headers with `gcc -fsyntax-only -Wall`. Both reference trees were later
re-baselined onto the official release tarballs and every claim below re-verified against them —
see **Part D**.

**Result: there is no C-level incompatibility.** Every blocker is in the build system, packaging,
or environment. Two environment facts drive the design:

1. **Debian 13 (trixie) ships no `asterisk` package at all.** Verified against
   `api.ftp-master.debian.org/madison`: asterisk exists in bullseye (16.28) and in
   testing/unstable = forky/sid (22.10.1), but **not in bookworm or trixie**;
   `packages.debian.org/trixie/asterisk` returns "Package not available". So on 64-bit Raspberry
   Pi OS, Asterisk 22 must be built from source — which is exactly what makes
   `/home/quectel/asterisk-22` the authoritative target.
2. **There are no installed Asterisk headers on this dev box either** — `asterisk-dev` was
   removed on 2026-08-31, so `/usr/include/asterisk.h`, `/usr/include/asterisk/`, `asterisk.pc`
   and the `asterisk` daemon are all absent, exactly as on the Pi. The source tree is therefore
   the *only* header source, on both machines.
   *(Historical: while `asterisk-dev` 22.5.2 was installed, `/usr/include/asterisk` was
   Debian-patched — `taskprocessor.h:217` / `threadpool.h:189` declared `ast_taskprocessor_push` /
   `ast_threadpool_push` as plain functions where upstream uses macros expanding to
   `__ast_taskprocessor_push(..., __FILE__, __LINE__, __PRETTY_FUNCTION__)`, and its
   `format_cache.h` carried Debian-only `ast_format_amr`/`amrwb`. That was the original reason to
   stop building against `/usr/include`; the packages being gone has now settled it.)*

**Decisions taken:** build Asterisk 22.11.0 from the `asterisk-22` tree on the Pi; configure a
**copy** of that tree so it yields usable headers while the reference tree stays byte-identical to
the upstream tarball; full scope (build, packaging, docker, OpenWRT, docs);
**Asterisk 22 becomes the hard minimum**.

---

## Part A — Every incompatibility, with evidence

### A.1 What is NOT a problem (verified, do not spend time here)

| Area | Finding |
| --- | --- |
| Headers used by `src/` | 25 headers + `asterisk.h`. **All exist in 22.** The two headers deleted in 22 (`monitor.h`, `pktccops.h`) are not referenced. |
| Header content | **19 of 25 byte-identical** 20→22: `asterisk.h`, `callerid.h`, `causes.h`, `cli.h`, `compiler.h`, `format.h`, `format_cache.h`, `frame.h`, `json.h`, `linkedlists.h`, `localtime.h`, `lock.h`, `logger.h`, `message.h`, `musiconhold.h`, `stringfields.h`, `strings.h`, `taskprocessor.h`, `threadpool.h`, `timing.h`. Also identical transitively: `astobj2.h`, `config.h`, `format_cap.h`. |
| The 6 changed headers | `app.h` (lost `ast_app_*_macro`), `channel.h` (lost `*_macro*`, `ast_channel_monitor*`), `manager.h` (`AMI_VERSION` string), `module.h` (doc comment only), `pbx.h` (lost `ast_context_*lockmacro`), `stasis_channels.h` (lost `ast_channel_monitor_*_type`). **None of the removed symbols appear anywhere in `src/`.** |
| `struct ast_channel_tech` | Byte-identical in 20, 22.11.0 **and** Debian 22.5.2. All 13 callbacks assigned in `src/channel.c:1210` match their 22 declarations exactly. |
| `struct ast_msg_tech` / `msg_send` | `message.h` byte-identical; `src/msg_tech.c:69` signature matches `message.h:75`. |
| `AST_MODULE_INFO` | `src/chan_quectel.c:1577` uses the plain-C variadic form (`module.h:557`), unchanged. No module API/ABI bump 20→22. |
| Taskprocessor/threadpool | `taskprocessor.h`, `threadpool.h` byte-identical 20→22; every API used in `src/monitor_thread.c` present. |
| `ast_json_*` | All 13 functions used are present; `json.h` unchanged. |
| `struct ast_codec` `quality` field | Irrelevant — `src/` never includes `codec.h` and defines no codec. |
| Deprecations | `attribute_deprecated` is applied to **nothing** in the 22 headers. No new `-Wdeprecated-declarations`. |
| Re-baseline onto release tarballs | The whole table was **re-verified** against `asterisk-20.21.0.tar.gz` / `asterisk-22.11.0.tar.gz`. Unchanged: `app.h`, `channel.h`, `manager.h`, `module.h`, `pbx.h`, `stasis_channels.h`, `utils.h` differ and nothing else does. |
| Upstream dev branches vs the pinned releases | Across the entire `include/` tree, GitHub `origin/20` / `origin/22` differ from the tarballs in exactly two files, both harmless: a `frame.h` doc-comment fix and an added `ast_taskprocessor_is_executing()` in `taskprocessor.h`. See **Part D.2**. |
| Version guards in `src/` | **Zero.** No `#if ASTERISK_VERSION_NUM` anywhere — keep it that way (commit `e93ef38` deleted the last shims). |
| Direct compile test | `src/{char_conv,error,eventfd,memmem,mixbuffer,ringbuffer,tty}.c` compile clean with `gcc -std=gnu99 -fsyntax-only -Wall -I/home/quectel/asterisk-22/include`. The rest stop only at the *generated* `ptime-config.h`, not at any Asterisk API. |

### A.2 Blockers — build system

| # | Blocker | Evidence | Effect |
| --- | --- | --- | --- |
| B1 | **No git tag.** `git tag -l` is empty. | `CMakeLists.txt:52-68` runs `git describe --match "v*" --long --tags` and `MESSAGE(FATAL_ERROR "Git - unable to describe")`. | Any `cmake --preset` aborts before anything else is evaluated. |
| B2 | **`AST_HEADER_DIR` at an unconfigured tree hard-fails.** `/home/quectel/asterisk-22/include` has `asterisk.h` + `asterisk/` (so `ScanAsteriskHeadersDirectory` returns `DIRECTORY`), but has **no `asterisk/autoconfig.h` and no `asterisk/buildopts.h`**. | `include/asterisk.h:21` `#include "asterisk/autoconfig.h"` makes `CHECK_INCLUDE_FILE(asterisk.h)` fail, so `CMakeLists.txt:208-211` aborts with `Asterisk header not found.` — the `FIND_PATH(… buildopts.h … REQUIRED)` at `:214` is **never reached**. Real cause only visible in `CMakeConfigureLog.yaml`: `asterisk.h:21:10: fatal error: asterisk/autoconfig.h: No such file or directory`. | Configure aborts with a misleading message. Since `asterisk-dev` was removed this is now the **first** failure of any configure attempt, with or without `AST_HEADER_DIR`. |
| B3 | **`ASTERISK_VERSION_NUM` silently defaults to `180000`.** No `asterisk.pc` exists here or on trixie. | `cmake/asterisk-version-num.cmake:36-39`; also defaulted to `180000` in `make-build-dir.cmake:13` and `configure-openwrt-makefile.cmake:6`. | A build against 22 headers is mislabelled as Asterisk 18 with no warning. Nothing derives it from the headers. Now **masked by B2** — configure dies before this matters — but unfixed. The tarballs ship `.version`, so the derive-from-`AST_HEADER_DIR` fix in Phase 2 step 6 works today. |
| B4 | **`AST_BUILDOPT_SUM` is computed from whatever `buildopts.h` is found.** `ShowAstBuildOptSum()` (`cmake/asterisk-headers.cmake:57-80`) `TRY_RUN`s `test/asterisk/AST_BUILDOPT_SUM.c` against the resolved include dir; the ctest (`cmake/test/AST_BUILDOPT_SUM.cmake`) then greps that 32-hex string out of the built `.so`. | `src/CMakeLists.txt:110`. | This is only a *self*-consistency check. It cannot detect a mismatch with the Asterisk actually installed on the Pi — and a mismatch is what makes Asterisk refuse to load the module (`main/loader.c:1836`). Building Asterisk and the driver from the same configured tree makes them match by construction. |
| B5 | **`build-arm64` / `package-arm64` presets do not exist.** | `install-chan-quectel.cmake:5-11` and `make-package.cmake:5-11` dispatch to them; `CMakePresets.json` defines only `default` and `openwrt`; `get-build-flags.sh` generates only `deb`, `rpi`, `rpm`. | `./install-chan-quectel.cmake arm64` fails. |
| B6 | **`clang-format` is found only under the bare name.** `FindClangFormat` (`cmake/clang-format.cmake:31`) does `FIND_PROGRAM(… NAME clang-format)`. Trixie's `clang-format` alternative is **19**; `ClangFormatFindAndCheck(18)` (`CMakeLists.txt:97`) then rejects it and silently skips the formatting targets. | `clang-format-18` (1:18.1.8-18) *is* packaged in trixie, just under a versioned binary name. | Formatting silently goes unchecked on the Pi. |
| B8 | **The daemon and the module install to different directories.** | `astmoddir` is `${libdir}/asterisk/modules` (`configure.ac:41`) and `libdir` defaults to `${exec_prefix}/lib`, so `--prefix=/usr` gives `/usr/lib/asterisk/modules`; `src/CMakeLists.txt:44-51` installs to `/usr/lib/<triplet>/asterisk/modules`. | The daemon never sees `chan_quectel.so`, silently. **Fixed in Part E.3** (`AST_LIBDIR`). |
| B9 | **`tools/configure-asterisk-22.sh` produces headers, not a usable daemon.** | It passes `--disable-xmldoc` and disables all six sound packages plus `format_gsm`. | A daemon built from that tree has no prompts, no music-on-hold, no `core show application`. **Fixed in Part E.3** (`AST_PROFILE`). |
| B10 | **`make install` leaves the daemon unrunnable as a service.** | No Makefile target installs `contrib/systemd/`; only `make config` installs a SysV script (`Makefile:929-948`). No `useradd`/`--with-asterisk-user` anywhere. `contrib/systemd/asterisk.service` is `Type=notify`, needing libsystemd at configure time (`configure.ac:2876`), which `install_prereq` never installs. | Without the unit and the account the daemon runs only by hand as root; with `Type=notify` and no libsystemd it is killed at `TimeoutStartSec`. **Documented, not automated — Part E.5** steps 1, 6, 8, 9. |
| B7 | ~~**Asterisk tree has no `.version`.**~~ **Closed by the tree re-baseline.** | Was: `build_tools/make_version:11-14` → `UNKNOWN__and_probably_unsupported` with neither `.version` nor `.git` — true of a GitHub dev-branch checkout. The release tarballs ship `.version` (`20.21.0`, `22.11.0`) and `make_version:7-10` reads it first. | None any more. See **Part D.3**. |

### A.3 Blockers — packaging (aarch64 / Debian 13)

| # | Blocker | Evidence |
| --- | --- | --- |
| P1 | **`asterisk16` dependency branch is dead weight** once 22 is the floor. | `CMakeLists.txt:323-329` `IF(${ASTERISK_VERSION_NUM} LESS 170000)`. |
| P2 | **`Depends: asterisk` is unsatisfiable on trixie** — there is no such package (see Context). A `.deb` declaring it cannot be installed with `dpkg -i` without `--force-depends`. | `CMakeLists.txt:327-328`. |
| P3 | **Architecture falls back to `amd64` silently.** | `CMakeLists.txt:283-284`: if `dpkg` is absent, `MESSAGE(WARNING …)` then `SET(CPACK_PACKAGE_ARCHITECTURE amd64)` — a warning is easy to miss and produces a mislabelled arm64 package. (With `dpkg` present on the Pi it correctly yields `arm64`.) |
| P4 | **`lintian` is mandatory for the `package` target.** `cpack/post-build-lintian.cmake` does `FIND_PROGRAM(… REQUIRED)` and requires version > 2.62, running with `--fail-on error,warning`. | `CMakeLists.txt:306-307`. Packaged in trixie, but must be installed. |
| P5 | Install path is already correct for aarch64 — `CMAKE_LIBRARY_ARCHITECTURE` resolves to `aarch64-linux-gnu` natively (`src/CMakeLists.txt:44-57`). **No change needed**, listed here so it is not "fixed" by mistake. |
| P6 | `cmake/test/needed-libs.cmake` `ALLOWED_LIBS` is `libasound libsqlite3 libc libpthread libgcc_s` plus `^ld-linux-`. `ld-linux-aarch64.so.1` matches. **Expected to pass unchanged** — verify, don't pre-emptively edit. |

### A.4 Blockers — cross-cutting

| # | Blocker | Evidence |
| --- | --- | --- |
| X1 | **No `configure-22` docker task.** `docker/task.d/asterisk/Taskfile.dist.yaml` defines only `old-configure-16` (:46), `configure-18` (:160), `configure-20` (:274). | Highest `ASTERISK_VERSION_NUM` pinned anywhere is `200100` (`docker/debian/12/Taskfile.dist.yaml:9`). |
| X2 | **No Debian 13 and no aarch64 Raspberry Pi docker image.** `docker/rpi-debian/{10,11,12}` only, and all are `DOCKER_PLATFORM: 'linux/arm/v6'` (`docker/rpi-debian/12/Taskfile.dist.yaml:9-10`). `docker/README.md:21` says "Raspberry Pi OS … 10, 11, 12 | armhf". arm64 exists only as amd64-host **cross**-compilation. | `grep -rni "trixie"` over the repo: zero hits. |
| X3 | **The old CI configure script's menuselect list is invalid for 22.** The deleted `git show master:.github/actions/install-asterisk-headers/configure-asterisk.sh` disables `chan_sip`, `chan_skinny`, `chan_mgcp`, `res_monitor`, `cdr_syslog`, `app_ices`, `app_image`, `app_nbscat` and enables `app_url` — **none of these modules exist in the 22 tree** (verified by file existence under `channels/`, `apps/`, `res/`, `cdr/`). `menuselect` exits non-zero on an unknown member, failing the whole chained command. (Unknown `--without-*` autoconf flags are only warnings, so the `./configure` half is safe.) |
| X4 | **OpenWRT defaults to major 18 with a warning.** `openwrt/CMakeLists.txt:18-23`. The `≤16` branch (`:24-34`) becomes dead code once 22 is the floor. |
| X5 | **README claims minimum 16.** `README.md:19` — the only version statement in the file. There is no Prerequisites/Installation/Platforms section at all (headings are only `# Changes`:15, `## General`:17, `## Configuration`:106, `## Commands`:218, `## Internal`:356). |
| X6 | **GCC 14 on trixie** (`gcc 4:14.2.0-1`) promotes `-Wimplicit-function-declaration`, `-Wincompatible-pointer-types`, `-Wint-conversion`, `-Wreturn-mismatch` to **errors** by default. The driver builds clean under GCC 15 here, so no problem is expected — but this must be verified on the Pi, not assumed. |

---

## Part B — Ordered action list

### Phase 0 — Unblock (do first; nothing else configures until these pass)

1. **Create the release tag.** `cmake -P make-release-tag.cmake` (requires a clean tree; emits
   `vYYYY.MM.DD` from the last commit's UTC date). Fallback: `git tag v2026.08.30`. Fixes **B1**.
2. **Install host prerequisites on the Pi** (all present in trixie):
   `build-essential cmake ninja-build git jq dpkg-dev lintian clang-format-18 libasound2-dev
   libsqlite3-dev` plus Asterisk's own: run `contrib/scripts/install_prereq install` from the
   asterisk-22 tree (pulls libedit, libjansson≥2.11, libuuid, libxml2, libssl, ncurses…).
   Note the bundled `third-party/{pjproject,jansson,libjwt}` are downloaded at configure time —
   the Pi needs network, or pass `--with-download-cache=<dir>`.

### Phase 1 — Turn a copy of `asterisk-22` into the authoritative header source

**Done — see Part E.** Steps 3 and 4 were already closed (Parts D.3 / D.6); step 4 gained
`AST_PROFILE` and `AST_LIBDIR` (Part E.3), and step 5 is the Raspberry Pi runbook in **Part E.5**.
Phase 1 also closed three blockers it discovered on the way: **B8**, **B9**, **B10** (Part E.2).

3. ~~Write `.version`.~~ **Done for us** — the release tarball ships it (**B7** closed, Part D.3).
4. **`tools/configure-asterisk-22.sh`** — **written** (Part D.6). It copies the reference tree and
   configures the *copy*, so the reference tree stays byte-identical to the upstream tarball and
   stays trustworthy to `diff` against. Derived from
   `git show master:.github/actions/install-asterisk-headers/configure-asterisk.sh`, with these
   changes (fixes **X3**):
   - **Deleted** these menuselect arguments — re-verified absent from the 22.11.0 tree:
     `--disable chan_sip`, `--disable chan_skinny`, `--disable chan_mgcp`,
     `--disable res_monitor`, `--disable cdr_syslog`, `--disable app_ices`,
     `--disable app_image`, `--disable app_nbscat`, `--enable app_url`.
     One stale name is worse than a non-zero exit: `menuselect.c:2178-2211` sets `res = 1`, which
     **skips `generate_makeopts_file()` entirely**, so `menuselect.makeopts` is never written.
   - **Dropped `--enable LOW_MEMORY`.** It was a 32-bit RPi1 optimisation; on a 64-bit Pi it only
     shrinks `AST_NUM_CHANNEL_BUCKETS` (`channel.h:154`) and `AST_PBX_MAX_STACK` (`pbx.h:1665`).
     It is deliberately excluded from the checksum by `build_tools/make_buildopts_h`, so it would
     *not* be caught by the `AST_BUILDOPT_SUM` test if it ever diverged.
   - Kept the `--without-*` list as-is; obsolete ones are harmless autoconf warnings
     (`./configure` reports `unrecognized options: --without-oss, --without-vpb,
     --without-sqlite, --without-misdn, --without-suppserv` and carries on).
   - **Made the codec group adaptive.** The CI list's `--with-speexdsp --with-ogg --with-opus
     --with-opusfile` makes those libraries *mandatory*, and `./configure` aborts at
     `checking for mandatory modules` if one is absent — which is exactly what happens on this
     dev box, where `libopusfile-dev` is not installed. The script now emits `--with-<lib>` only
     when `pkg-config` sees the library and `--without-<lib>` otherwise; `AST_CODEC_ARGS`
     overrides the whole group. None of the four is needed by chan_quectel.
   - Ends with `make menuselect.makeopts`, the `menuselect/menuselect …` call, and
     `make include/asterisk/buildopts.h` (`Makefile:417`), then asserts **both**
     `include/asterisk/autoconfig.h` and `include/asterisk/buildopts.h` exist. Fixes **B2**.
5. **Build and install Asterisk 22.11.0 on the Pi from that same configured copy**
   — with `AST_PROFILE=daemon`, and `make samples OVERWRITE=y` rather than `make config`;
   the full command list is **Part E.5**.
   Because the module and the daemon come from one configured tree — the copy made in step 4,
   not the pristine reference tree — their `AST_BUILDOPT_SUM`
   agree by construction and `main/loader.c:1836` will accept the module. Resolves **B4**.
   *(Note: `build_tools/make_buildopts_h` is byte-identical between 20 and 22, so the checksum
   mechanism itself did not change.)*

### Phase 2 — Retarget the chan-quectel build

6. **`cmake/asterisk-version-num.cmake` — replace the `180000` fallback** (fixes **B3**).
   New resolution order in `CheckAsteriskVersion()`:
   cached → **derive from `AST_HEADER_DIR`** (read `<tree>/.version`, else parse
   `AC_INIT([asterisk], [NN]` out of `<tree>/configure.ac`; both give `22` → `220000`) →
   pkg-config → `MESSAGE(FATAL_ERROR)`. Never silently default.
   Then add the floor: `IF(ASTERISK_VERSION_NUM LESS 220000) MESSAGE(FATAL_ERROR …)`.
   Update the `180000` literals in `make-build-dir.cmake:13` and
   `configure-openwrt-makefile.cmake:6` to `220000`.
7. **`CMakeLists.txt:208-217` — give header discovery a real diagnostic.** Two sites, and the
   first one is the one users actually hit: `CHECK_INCLUDE_FILE(asterisk.h)` at `:208-211` fails
   on a missing `asterisk/autoconfig.h` and reports only `Asterisk header not found.`. Make that
   message distinguish "no headers at all" from "found an *unconfigured* tree", and in the latter
   case name `tools/configure-asterisk-22.sh`. Do the same for the `FIND_PATH(… buildopts.h …
   REQUIRED)` at `:214`. Keep both probes; do not weaken them.
8. **Add a native aarch64 preset.** Extend `get-build-flags.sh` with an `rpi64` variant (mirroring
   `rpi`, which forces `CPACK_DEBIAN_PACKAGE_SHLIBDEPS=ON`) that also seeds
   `AST_HEADER_DIR` and `ASTERISK_VERSION_NUM=220000`. Do **not** add a toolchain file — a native
   aarch64 build needs none; `cmake/toolchain/*` are cross-compilation only, and pointing at one
   would wrongly set `CMAKE_CROSSCOMPILING`.
9. **`cmake/clang-format.cmake` — widen `FindClangFormat`** to
   `FIND_PROGRAM(… NAMES clang-format-18 clang-format …)` (fixes **B6**). Workaround until then:
   `-DCLANG_FORMAT=/usr/bin/clang-format-18` (it is a `CACHE FILEPATH`).

### Phase 3 — Packaging

10. **`CMakeLists.txt:323-329` — delete the `asterisk16` branch** (**P1**) and reconsider
    `CPACK_DEBIAN_PACKAGE_DEPENDS` (**P2**). Since Asterisk is self-built on trixie, a hard
    `Depends: asterisk` is unsatisfiable — demote to `Enhances`/`Recommends`, or expose it as a
    cache variable defaulting to empty. Keep `Recommends: usb-modeswitch` (`:322`).
11. **`CMakeLists.txt:283-284` — make the missing-`dpkg` path fatal** (or derive the arch from
    `CMAKE_LIBRARY_ARCHITECTURE`) instead of silently stamping `amd64` (**P3**).
12. **Add the missing presets** `build-arm64` / `package-arm64` referenced by
    `install-chan-quectel.cmake:5-11` and `make-package.cmake:5-11`, or teach those two scripts a
    native/no-argument path (**B5**).
13. **Document the `lintian` requirement** in the new README build section, or make
    `cpack/post-build-lintian.cmake` skip gracefully when absent (**P4**).

### Phase 4 — Docker

14. **Add a `configure-22` task** to `docker/task.d/asterisk/Taskfile.dist.yaml`, copied from
    `configure-20` (:274) with the same module removals as step 4 (**X1**).
15. **Add `docker/rpi-debian/13/`** (trixie): `DOCKER_PLATFORM: 'linux/arm64'`,
    `ASTERISK_VERSION_NUM: '220000'`, and — unlike 10/11/12 which `apt install asterisk-dev` —
    it must **build Asterisk from source** via the new `configure-22` task, because trixie has no
    asterisk package (**X2**). Add the `bookworm`-style symlink convention (`trixie -> 13`) and
    update `docker/README.md:21`.
16. **Retire the 16/18/20 targets** consistent with "22 is the minimum": remove or park
    `docker/{debian,rpi-debian}/{10,11,12}`, `docker/centos`, `docker/ubuntu/{20.04,22.04}` and
    the matching `docker/arm-gnu-toolchain/*` entries, plus `old-configure-16` / `configure-18` /
    `configure-20`.

### Phase 5 — OpenWRT

17. **`openwrt/CMakeLists.txt:18-34`** — make the undefined-version branch fatal instead of
    assuming 18, and delete the now-dead `ASTERISK_MAJOR_VER ≤ 16` branch together with the
    `diffconfig.in` → `diffconfig-gen` generation it drives (**X4**). Regenerate via
    `cmake -P configure-openwrt-makefile.cmake 220000` and confirm the plain `asterisk` package
    name path (`:35-44`) is taken.

### Phase 6 — Documentation

18. **`README.md:19`** → "Minimal supported Asterisk version is **22**" (**X5**).
19. **Add a `## Building` section to `README.md`** — none exists. Cover: trixie/aarch64
    prerequisites, `tools/configure-asterisk-22.sh`, building Asterisk from source (and *why* —
    no trixie package), the `AST_HEADER_DIR` / `ASTERISK_VERSION_NUM=220000` invocation, and the
    tag requirement.
20. **Update `.claude/CLAUDE.md`** — partly **done** (Part D.7): the reference-tree description,
    the `180000` paragraph, the blessed sequence, header discovery, and the `asterisk-dev`
    dependency all now reflect the release tarballs and the absent system headers, and §3 records
    the pinned versions plus the `ast_frame_adjust_volume()` semantics. Still to do once Phases
    2-5 land: the `180000` default disappearing, the `rpi64` preset, and any convention change
    in §4. Absolute paths stay out of `CLAUDE.md` — they live in `.claude/CLAUDE.local.md`.
21. **Copy this plan to `plan.md`** at the repo root, as requested.

---

## Part C — Phase 0 implementation record

Executed 2026-08-31. Phase 0 closes exactly one blocker — **B1** — and provisions the Raspberry
Pi. Nothing under `src/`, `cmake/`, `docker/` or `openwrt/` was touched, and neither Asterisk
tree was configured; those are Phases 1–6.

### C.1 — Done in the repository

**Release tag created** (Phase 0, step 1). Run from the repo root on branch `asterisk-22` with a
clean working tree — the script refuses a dirty one (`make-release-tag.cmake:13-15`):

```sh
cmake -P make-release-tag.cmake
# -- Package version: v2026.08.30
```

The name is derived by the script from the **committer timestamp of `HEAD`**, not from the
current date: `git log -n 1 --pretty=format:%H;%ct` → `1788132933` →
`date --utc --date=@1788132933 +v%Y.%m.%d` → `v2026.08.30`.

The result is an **annotated** tag (`git tag -a -m "Package version"`), which is what
`git describe --tags` needs in order to emit the `-N-g<sha>` suffix the version regex expects:

```
$ git cat-file -t v2026.08.30
tag
$ git cat-file -p v2026.08.30
object 5d30d81dd3d11953ef4f7f076058ff810dc61898
type commit
tag v2026.08.30
tagger Gergo Vladiszavlyev <github@ruszki.com> 1788153456 +0000

Package version
```

Pushed to `origin`, so the Pi only needs `git fetch --tags`:

```
$ git push origin v2026.08.30
 * [new tag]         v2026.08.30 -> v2026.08.30
$ git ls-remote --tags origin v2026.08.30
cbeda540cb66a5e2d50a420687e7b44012679864	refs/tags/v2026.08.30
```

**Evidence B1 is closed.** Before:

```
$ git describe --abbrev=6 --dirty --match "v*" --long --tags
fatal: No names found, cannot describe anything.
```

After — configure gets past `CMakeLists.txt:68` instead of aborting there.

> **This log is historical.** It was taken while `asterisk-dev` 22.5.2 was still installed, so
> configure silently fell back to `/usr/include`. Those packages were removed on 2026-08-31 and
> the run is no longer reproducible — see **Part D.4** for what the same command does now.

```
$ git describe --abbrev=6 --dirty --match "v*" --long --tags
v2026.08.30-0-g5d30d8

$ cmake -S . -B <throwaway-dir> -DASTERISK_VERSION_NUM=220000
-- Looking for clang-format executable - not found
-- Project version: 2026.8.30
-- Asterisk version: 220000 [cached]
-- Asterisk header directory: /usr/include/
-- Getting AST_BUILDOPT_SUM - 1fb7f5c06d7a2052e38d021b3d8ca151
-- Found ALSA: /usr/lib/x86_64-linux-gnu/libasound.so (1.2.15.3)
-- Found SQLite3: /usr/lib/x86_64-linux-gnu/libsqlite3.so (3.46.1)
CMake Warning at src/CMakeLists.txt:126 (MESSAGE):
  Cannot create formatting targets - clang-format not found
-- Configuring done (3.7s)
```

Three lines in that log were worth recording; **none of them was fixed by Phase 0**:

- `Asterisk header directory: /usr/include/` — the dev box silently fell back to the
  **Debian-patched** headers, precisely the hazard described in Context §2. The reported
  `AST_BUILDOPT_SUM` `1fb7f5c06d7a2052e38d021b3d8ca151` therefore belonged to Debian's
  asterisk-dev 22.5.2, **not** to 22.11.0, and was meaningless for the Pi. Removing
  `asterisk-dev` has since made this fallback impossible; **B2** is what makes the source tree
  usable instead.
- `Asterisk version: 220000 [cached]` — only because it was passed on the command line. Drop the
  flag and `180000` is still assumed with no warning (**B3**).
- `clang-format not found` — this dev box has none at all; on the Pi it *will* be found, but
  rejected as version 19 (**B6**).

**The tag going stale is expected.** Once the commit carrying this chapter lands, `git describe`
returns `v2026.08.30-1-g<sha>`. The regex at `CMakeLists.txt:59` still matches, with
`CHAN_VER_TWEAK` = `1` and `CHAN_STATUS` = `-g<sha>`, so B1 stays closed. Re-run
`cmake -P make-release-tag.cmake` only when cutting an actual release.

### C.2 — Raspberry Pi command list (Phase 0, step 2)

Everything below runs **on the Pi**, as the normal login user (member of `sudo`). Assumes a
fresh 64-bit Raspberry Pi OS (trixie) with network access and **≥ 5 GB free on `/`**.

Run the blocks in order and check the expected output before moving on.

#### 0. Sanity check the machine

```sh
uname -m
. /etc/os-release; echo "$ID $VERSION_ID $VERSION_CODENAME"
nproc
free -m
df -h /
```

Expect `aarch64` and `debian 13 trixie`. **If `uname -m` says `armv7l` or `armhf`, stop** — this
is a 32-bit userland and the whole plan targets aarch64.

#### 1. Base packages

```sh
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y \
    build-essential cmake ninja-build git jq dpkg-dev lintian clang-format-18 \
    libasound2-dev libsqlite3-dev pkg-config curl wget ca-certificates
```

Verify:

```sh
gcc --version | head -1
cmake --version | head -1
ninja --version
jq --version
lintian --version
clang-format-18 --version
dpkg-buildflags --version | head -1
```

What matters:

- **`clang-format-18` must report 18.x.** `ClangFormatFindAndCheck(18)` at `CMakeLists.txt:97`
  accepts nothing else. Trixie's unversioned `clang-format` alternative is **19** and will be
  rejected, silently skipping the formatting targets (**B6**). Until B6 is fixed in Phase 2
  step 9, pass `-DCLANG_FORMAT=/usr/bin/clang-format-18` on the CMake command line — it is a
  `CACHE FILEPATH`.
- **`lintian` must be > 2.62** (`cpack/post-build-lintian.cmake` requires it, and finds it
  `REQUIRED`). Trixie ships 2.122.0 (**P4**).
- **gcc is 14.2.0** on trixie. It promotes `-Wimplicit-function-declaration`,
  `-Wincompatible-pointer-types`, `-Wint-conversion` and `-Wreturn-mismatch` to hard errors
  (**X6**). Nothing to do now; this is verified when the driver is actually built.

#### 2. Clone the driver and pick up the tag

```sh
mkdir -p ~/src
cd ~/src
git clone https://github.com/ruszki/asterisk-chan-quectel.git
cd ~/src/asterisk-chan-quectel
git checkout asterisk-22
git fetch --tags
git describe --abbrev=6 --dirty --match "v*" --long --tags
```

The last command **must** print something starting with `v2026.08.30-`. If it prints
`fatal: No names found`, the tag did not come across — recreate it locally (the tree must be
clean):

```sh
cmake -P make-release-tag.cmake     # → -- Package version: v2026.08.30
```

If you use SSH rather than HTTPS for GitHub, substitute
`git clone git@github.com:ruszki/asterisk-chan-quectel.git`.

#### 3. Fetch the Asterisk 22.11.0 source

Asterisk must be built from source: **trixie ships no `asterisk` package at all** (see Context
§1), and building the daemon and the module from one configured tree is what makes their
`AST_BUILDOPT_SUM` agree by construction (**B4**).

```sh
cd ~/src
wget https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-22.11.0.tar.gz
echo '3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94  asterisk-22.11.0.tar.gz' | sha256sum -c -
tar xzf asterisk-22.11.0.tar.gz
mv asterisk-22.11.0 asterisk-22
ls ~/src/asterisk-22/configure
```

Checksums re-verified 2026-08-31 by downloading the tarball again. `/home/quectel/asterisk-22` on
the dev box is now byte-identical to what this step produces (Part D.1), so the two machines look
the same from here on.

`sha256sum -c -` must print `asterisk-22.11.0.tar.gz: OK`. (The checksum sidecar upstream is
`asterisk-22.11.0.sha256` — note it is *not* named `…tar.gz.sha256`; that URL 404s. md5 is
`077b09bd6e449f68f03da44c85b86dde`, size 26 724 408 bytes.)

#### 4. Asterisk's own prerequisites

Preview what will be installed first:

```sh
cd ~/src/asterisk-22
sudo contrib/scripts/install_prereq test | head -40
```

Then install:

```sh
sudo contrib/scripts/install_prereq install
```

Expect this to take a while and pull roughly 80 `-dev` packages (1–2 GB). Two things that look
alarming but are normal:

- The script installs `aptitude` first if it is missing (`install_prereq:279-281`).
- Several names in its Debian list no longer exist in trixie — `libneon27-dev`,
  `libgmime-2.6-dev`, `libmysqlclient-dev`, `libsrtp0-dev`, `libc-client2007e-dev`,
  `libresample1-dev`, `libiksemel-dev`. They are **filtered out**, not failed on:
  `check_installed_debs()` (`install_prereq:210-217`) selects only packages `aptitude search`
  actually knows about.

Verify the libraries that matter to Asterisk 22:

```sh
pkg-config --modversion jansson libedit uuid libxml-2.0 sqlite3 openssl alsa
```

`jansson` must be **≥ 2.11**.

#### 5. Optional — swap headroom

Only if `free -m` in step 0 showed less than 4 GB of RAM. Building Asterisk with `-j4` on a 2 GB
Pi will OOM otherwise (the alternative is simply `make -j2`).

```sh
sudo dphys-swapfile swapoff
sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
sudo dphys-swapfile setup
sudo dphys-swapfile swapon
free -m
```

#### 6. Note — offline builds only

`third-party/{pjproject,jansson,libjwt}` are downloaded during Asterisk's `./configure`. With
network on the Pi there is nothing to do here. Without it, the tarballs must be staged on
another machine and `./configure --with-download-cache=<dir>` used in Phase 1.

#### 7. Phase 0 exit check

One copy-paste block. Everything must be `OK`:

```sh
cd ~/src/asterisk-chan-quectel
git describe --abbrev=6 --dirty --match "v*" --long --tags
for t in gcc cmake ninja git jq dpkg-buildflags lintian clang-format-18 wget; do
    command -v "$t" >/dev/null && echo "OK      $t" || echo "MISSING $t"
done
test -x ~/src/asterisk-22/configure && echo "OK      asterisk-22 source" || echo "MISSING asterisk-22 source"
pkg-config --modversion jansson
```

#### 8. Stop here

Do **not** run `./configure` or `make` in `~/src/asterisk-22` — **ever**, not just "not yet".
Keeping that tree byte-identical to the upstream tarball is what makes `diff` against it a
trustworthy answer to API questions. Phase 1 step 4 works on a **copy**:
`AST_PROFILE=daemon tools/configure-asterisk-22.sh ~/src/asterisk-22` writes
`~/src/asterisk-22-configured` and prints the `AST_HEADER_DIR` to use — see **Part E.5** for the
full sequence. Configuring by hand would also skip the menuselect fixes the
script carries (**X3**).

### C.3 — Status after Phase 0

*(Superseded by **Part E.6**, which carries the state after Phase 1.)*

| Blocker | State | Closed by |
| --- | --- | --- |
| **B1** no git tag | **Fixed** — `v2026.08.30` created and pushed | Phase 0 |
| B2 unconfigured tree → `Asterisk header not found.` at `CMakeLists.txt:208-211` | **Fixed in practice** — `tools/configure-asterisk-22.sh` produces a usable header dir; verified by a full configure + build + ctest (Part D.8). The misleading *message* is still Phase 2, step 7 | Part D.6 |
| B3 `ASTERISK_VERSION_NUM` defaults to `180000` | open, currently masked by B2 | Phase 2, step 6 |
| B4 `AST_BUILDOPT_SUM` self-consistency only | open | Phase 1, step 5 (by construction) |
| B5 missing `build-arm64` / `package-arm64` presets | open | Phase 3, step 12 |
| B6 `clang-format` found only under the bare name | open (workaround: `-DCLANG_FORMAT=/usr/bin/clang-format-18`) | Phase 2, step 9 |
| B7 Asterisk tree has no `.version` | **Fixed** — the release tarballs ship it | tree re-baseline (Part D.3) |
| P1–P4 packaging | open | Phase 3 |
| P5, P6 | verified as already correct — do not "fix" | — |
| X1, X2 docker | open | Phase 4 |
| X3 menuselect list invalid for 22 | **Fixed** — `tools/configure-asterisk-22.sh` written | Part D.6 |
| X4 OpenWRT | open | Phase 5 |
| X5 README | open | Phase 6 |
| X6 GCC 14 promoted warnings | unverified — needs a real build on the Pi | Verification, step 4 |

One housekeeping consequence: `get-source-date-epoch.sh` aborts on a dirty tree unless `PRESET`
is set, so **commit this chapter before attempting the blessed reproducible-build sequence**.

---

## Part D — Reference-tree re-baseline and loss of installed headers

Recorded 2026-08-31. Two environment changes landed at once: the reference Asterisk trees were
replaced with official release tarballs, and `asterisk-dev` was uninstalled. Everything below was
re-verified from scratch; nothing here is carried over from Parts A–C.

**Bottom line: no new porting work.** The swap closes **B7**, corrects the diagnosis of **B2**,
retires the Context §2 rationale, and makes the dev box match the Pi. It also surfaced one latent
bug in `src/channel.c` (D.5) that is unrelated to the Asterisk version.

### D.1 — The trees are the official release tarballs, byte for byte

Both tarballs were downloaded and unpacked, and `diff -rq` against the local trees produced
**empty output** — prefetched `sounds/*.tar.gz` included:

| tree | tarball | sha256 |
| --- | --- | --- |
| `/home/quectel/asterisk-20` | `asterisk-20.21.0.tar.gz` | `13fd6e8f1fbb19a3174af82a388dd72c87eb2c92d32fca83c4d51bfab03f686a` |
| `/home/quectel/asterisk-22` | `asterisk-22.11.0.tar.gz` | `3bd5ee040509a3d3cd9b1ba9520c18e6ec0a7e7981ca68c457dcd36ba3c54d94` |

Both are the newest releases (tagged 2026-08-27). Previously the trees were GitHub **dev-branch**
checkouts (`origin/20`, `origin/22`, tip 2026-08-18). Release tags are cut on `releases/NN`, a
branch that forked from `NN` at 2024-08-14, which is why `git rev-list 22.11.0..origin/22` reports
564 commits — that is divergence bookkeeping between two parallel histories, not missing content.

Relative to the git tag, the tarball only drops `.github/` and adds the two sound archives.

### D.2 — Old vs new: the complete delta is two files

Across the **entire `include/` tree**, dev-branch tip vs release tarball differs in exactly two
files, identically for 20 and 22:

- **`include/asterisk/frame.h`** — doc comment only (upstream `688affc653`, post-22.11.0,
  *"frame: Correct ast_frame_adjust_volume\* documentation of 'adjustment'"*). It restates the
  `adjustment` parameter as a **linear gain factor, not a dB value**: positive multiplies each
  sample by the magnitude, negative divides, `0` is a no-op, and `10^(dB/20)` converts. No code
  change — `main/frame.c` is byte-identical in 20.21.0 and 22.11.0 and has always behaved this way.
- **`include/asterisk/taskprocessor.h`** — the dev branch adds
  `unsigned int ast_taskprocessor_is_executing(const struct ast_taskprocessor *tps);`. Purely
  additive, absent from 22.11.0, unused here.

`build_tools/`, `main/loader.c`, `configure.ac` and `contrib/scripts/install_prereq` are
byte-identical between dev tip and release, so the `AST_BUILDOPT_SUM` machinery and the prereq
list are unaffected.

The 20-vs-22 comparison in **A.1** was re-run against the tarballs and is unchanged: of the 27
Asterisk headers `src/` includes, only `app.h`, `channel.h`, `manager.h`, `module.h`, `pbx.h`,
`stasis_channels.h` and `utils.h` differ; `monitor.h` / `pktccops.h` are absent from 22 and unused;
`AMI_VERSION` goes `"9.0.0"` → `"11.0.0"`; `codec.h` gains `quality`. `frame.h` and
`taskprocessor.h` are byte-identical *between* 20.21.0 and 22.11.0.

### D.3 — `.version` now ships (B7 closed)

`cat /home/quectel/asterisk-22/.version` → `22.11.0` (and `20.21.0` for the other tree). Dev
branches carry no `.version`, which is what B7 recorded. `build_tools/make_version:7-10` reads it
before falling back to git, so the tree self-reports correctly and Phase 1 step 3 is unnecessary.

It also makes the Phase 2 step 6 plan — resolve `ASTERISK_VERSION_NUM` from
`<AST_HEADER_DIR>/../.version` before touching pkg-config — implementable today.

The trees remain **unconfigured**: no `autoconfig.h`, `buildopts.h`, `makeopts`,
`menuselect.makeopts` or `menuselect-tree`. `include/asterisk/autoconfig.h.in` and a pre-generated
`configure` are present, so `bootstrap.sh` is not needed.

### D.4 — `asterisk-dev` removed: what configure does now

Verified absent: `/usr/include/asterisk.h`, `/usr/include/asterisk/`, `asterisk.pc`, the `asterisk`
daemon. Also gone from the box: `jq`, `ninja`, `lintian`, `clang-format` (any version). Present:
`cmake`, `gcc 15.2.0`, `pkg-config`, `dpkg-buildflags`.

```
$ cmake -S . -B <throwaway> -DASTERISK_VERSION_NUM=220000
-- Project version: 2026.8.30-1-g086e12
-- Asterisk version: 220000 [cached]
-- Looking for asterisk.h
-- Looking for asterisk.h - not found
CMake Error at CMakeLists.txt:210 (MESSAGE):
  Asterisk header not found.
```

Adding `-DAST_HEADER_DIR=/home/quectel/asterisk-22/include` fails at the **same** line.
`CMakeConfigureLog.yaml` names the real cause:

```
/home/quectel/asterisk-22/include/asterisk.h:21:10: fatal error: asterisk/autoconfig.h: No such file or directory
```

Consequences:

- **B2's failure order in A.2 was backwards** and has been corrected there. The abort is
  `CHECK_INCLUDE_FILE(asterisk.h)` at `CMakeLists.txt:208-211`; `FIND_PATH(… buildopts.h …
  REQUIRED)` at `:214` is unreachable. The message users see is the unhelpful
  `Asterisk header not found.` — hence the widened Phase 2 step 7.
- **Context §2's original rationale is retired.** The Debian-patched-headers hazard cannot occur;
  those headers do not exist. The conclusion it supported still stands, for a simpler reason.
- **B3 is masked, not fixed.** `cmake/asterisk-version-num.cmake:36-39` still defaults to `180000`.
- `asterisk-headers.sh`'s `DEF_AST_DIR=/usr/include` default is dead; it now needs an explicit
  directory argument, and that directory must be a **configured** tree's `include/` — an archive
  built from an unconfigured tree reproduces the `autoconfig.h` failure inside `build/include`.
- `./get-build-flags.sh` needs `jq` (`:171-192`), so the blessed reproducible-build sequence cannot
  run on this dev box at all. Only the Pi runs it.
- `docker/rpi-debian/{11,12}/Dockerfile` still `apt install asterisk-dev`; unchanged here, but it
  reinforces Phase 4 step 15 — the trixie image must build Asterisk from source.

### D.5 — Latent bug found via the `frame.h` doc fix (recorded, not fixed)

`src/channel.c:661-681`, in the `CONF_SHARED(pvt, multiparty)` write path:

```c
/** try to minimize of ast_frame_adjust_volume() calls:
 *  one hand we must obey txgain but with other divide gain to
 *  number of mixed channels. ... */
int gains[2];
gains[1] = mixb_streams(&pvt->write_mixb);   /* stream count, always positive */
if (gains[1] < 1 || pvt->a_timer == NULL) { gains[1] = 1; }
gains[0] = 0;
for (size_t count = 0; count < ARRAY_LEN(gains); ++count) {
    if (gains[count] > 1 || gains[count] < -1) {
        if (ast_frame_adjust_volume(f, gains[count]) == -1) { ... }
    }
}
```

`main/frame.c` (byte-identical in 20.21.0 and 22.11.0) applies
`ast_slinear_saturated_multiply` for a **positive** `adjustment` and
`ast_slinear_saturated_divide` only for a **negative** one. Passing a positive stream count
therefore **multiplies** the frame by the number of mixed streams — the opposite of the comment's
stated intent, and a clipping/saturation source. `gains[0]` is hardcoded to `0`, so the txgain half
of the comment is dead code and the loop is a two-iteration wrapper around one effective call.

**Not fixed on this branch, deliberately.** It is guarded by `multiparty`, which is off by default
and whose calls the driver actively rejects, so it is latent rather than a live regression, and
fixing it is unrelated to the Asterisk 22 migration. The correct change, when it is made, is to
pass `-gains[1]` (and to drop the dead slot).

### D.6 — `tools/configure-asterisk-22.sh` written

Closes **X3** and is the mechanism for **B2**. Contract:

```
tools/configure-asterisk-22.sh [<src-tree>] [<dest-tree>]
  <src-tree>   default $ASTERISK_22_SRC     - unconfigured release tarball, never modified
  <dest-tree>  default $ASTERISK_22_BUILD, else <src-tree>-configured
  FORCE=1                  reconfigure an existing destination
  AST_DOWNLOAD_CACHE=<dir> passed as --with-download-cache, for an offline configure
  prints <dest-tree>/include on stdout - the AST_HEADER_DIR value
```

It refuses a tree whose `.version` is missing or not `22.*`, copies with `cp -a`, runs `./configure`
with the inherited `--without-*` list plus an adaptive codec group, then `make menuselect.makeopts`,
the corrected `menuselect/menuselect` call, and `make include/asterisk/buildopts.h`
(`Makefile:417`), finally asserting both generated headers exist and echoing the resulting
`AST_BUILDOPT_SUM`. All build chatter goes to stderr so stdout carries only the path, making
`AST_INC=$(tools/configure-asterisk-22.sh …)` work. Re-running against an already-configured
destination is a no-op unless `FORCE=1`.

The CI list's `--with-speexdsp --with-ogg --with-opus --with-opusfile` makes those libraries
mandatory and aborts `./configure` at `checking for mandatory modules` when one is missing —
`libopusfile-dev` is absent here, so each is demoted to `--without-` unless `pkg-config` finds it.
`AST_CODEC_ARGS` overrides the group.

Why a copy rather than in-place: the reference tree's whole value is being byte-identical to the
shipped tarball, which is what makes `diff` against it a trustworthy answer to an API question
(A.1, D.2). C.2 step 8 is updated accordingly.

The nine removed menuselect members were re-verified absent from 22.11.0 by file existence under
`channels/`, `apps/`, `res/`, `cdr/`. This matters more than X3 implied: `menuselect.c:2178-2211`
sets `res = 1` for an unknown `--enable`/`--disable` member, and `res != 0` **skips
`generate_makeopts_file()`**, so `menuselect.makeopts` is silently never written. Every other
member of the old CI list — including `chan_unistim`, `chan_iax2`, `chan_motif`, `res_snmp`,
`res_adsi`, `app_sms`, `app_test`, `app_flash`, `app_festival`, `app_mp3`, `astdb2sqlite3`,
`astdb2bdb`, `astcanary` — does still exist in 22 and was kept.

### D.7 — Documentation updated

- **`plan.md`** (this file): Context §2 rewritten; A.1 gained two rows; B2 re-diagnosed; B3 noted
  as masked; B7 closed; Phase 1 steps 3–5, Phase 2 step 7 and Phase 6 step 20 revised; C.1's
  configure log marked historical; C.2 steps 3 and 8 revised; C.3 status table updated.
- **`.claude/CLAUDE.md`**: reference-tree bullets, the `ASTERISK_VERSION_NUM` paragraph, the
  blessed sequence, "Finding the Asterisk headers", the dependency list, §2's audio paragraph and
  §3's preamble and rules. Still free of absolute paths.
- **`.claude/CLAUDE.local.md`**: the machine-specific facts — tree paths and pinned versions, the
  configured-copy location, what is not installed, and the working `cmake` invocation.
- **`tools/configure-asterisk-22.sh`**: new, see D.6.

### D.8 — End-to-end verification actually run

On this dev box, against the configured copy — not the reference tree:

```
$ AST_INC=$(tools/configure-asterisk-22.sh /home/quectel/asterisk-22 <dest>)
pkg-config cannot see opusfile - configuring --without-opusfile
AST_BUILDOPT_SUM: da6642af068ee5e6490c5b1d2cc1d238

$ cmake -S . -B <build> -DASTERISK_VERSION_NUM=220000 -DAST_HEADER_DIR="$AST_INC" -DBUILD_TESTING=ON
-- Asterisk version: 220000 [cached]
-- Looking for asterisk.h - found
-- Asterisk header directory: <dest>/include/
-- Getting AST_BUILDOPT_SUM - da6642af068ee5e6490c5b1d2cc1d238

$ cmake --build <build> -j$(nproc)
[100%] Built target asterisk-chan-quectel

$ ctest
1/4 Load library ................ Passed
2/4 Check library dependencies .. Passed
3/4 Check comment section ....... Passed
4/4 Check AST_BUILDOPT_SUM ...... Passed
100% tests passed, 0 tests failed out of 4
```

So **B2 is closed in practice** and the driver compiles and links clean against 22.11.0 headers on
x86-64/GCC 15 — no `#if ASTERISK_VERSION_NUM` guard, no source change. The only compile warnings
are pre-existing: three `struct … declared inside parameter list` from Asterisk's own `codec.h` /
`format.h` in a CMake probe TU, and `src/memmem.c:55` `-Wdiscarded-qualifiers`.

Caveats that keep the rest of the plan alive: the reference tree stayed pristine
(`diff -rq` against the tarball is still empty); `da6642af068ee5e6490c5b1d2cc1d238` belongs to
*this* option set on *this* host, so the Pi must take its checksum from the tree its own daemon is
built from (**B4**); `Check architecture-specific metadata` did not run (cross-compile only); and
GCC 14 on the Pi still has to be verified (**X6**).

### D.9 — How to re-check this chapter

```sh
# the reference trees must still be pristine
test ! -e /home/quectel/asterisk-22/include/asterisk/autoconfig.h
cat /home/quectel/asterisk-22/.version                       # 22.11.0

# only these seven driver headers may differ between 20 and 22
for h in app.h callerid.h causes.h channel.h cli.h compiler.h format.h format_cache.h \
         frame.h json.h linkedlists.h localtime.h lock.h logger.h manager.h message.h \
         module.h musiconhold.h pbx.h stasis_channels.h stringfields.h strings.h \
         taskprocessor.h threadpool.h timing.h utils.h; do
    diff -q /home/quectel/asterisk-{20,22}/include/asterisk/$h
done

# the volume semantics behind D.5
sed -n '/^int ast_frame_adjust_volume(/,/^}/p' /home/quectel/asterisk-22/main/frame.c
```

---

## Part E — Phase 1 implementation record

Executed 2026-08-31. Phase 1 is `plan.md` steps 3–5. Steps 3 and 4 were already closed before this
chapter began — the release tarball ships `.version` (**B7**, Part D.3) and
`tools/configure-asterisk-22.sh` was written in `babddcc` (Part D.6) — so the work was step 5:
**build and install Asterisk 22.11.0 on the Pi from the same configured copy the driver compiles
against**, which is what makes their `AST_BUILDOPT_SUM` agree by construction (**B4**).

Preparing step 5 exposed three things the script could not do yet. They are written up as **B8**,
**B9** and **B10** in §E.2 and are fixed here; the Pi runbook in §E.5 assumes those fixes.
Nothing under `src/`, `cmake/`, `docker/` or `openwrt/` was touched, and neither reference tree
was configured in place.

### E.1 — `AST_BUILDOPT_SUM` is a function of the option set, not of the host

This is the fact the whole chapter rests on, and it was not established before.
`build_tools/make_buildopts_h` hashes **only** `MENUSELECT_CFLAGS`, after deleting a fixed list of
non-ABI flags — `AO2_DEBUG`, `BETTER_BACKTRACES`, `BUILD_NATIVE`, `COMPILE_DOUBLE`, `DEBUG_CHAOS`,
`DEBUG_SCHEDULER`, `DONT_OPTIMIZE`, `DUMP_SCHEDULER`, `LOTS_OF_SPANS`, `MALLOC_DEBUG`,
`RADIO_RELAX`, `REBUILD_PARSERS`, `REF_DEBUG`, `USE_HOARD_ALLOCATOR` and, uniquely in the checksum
branch, `LOW_MEMORY`. `AST_DEVMODE` is excluded too, by its own comment.

With this script's menuselect call the file `menuselect.makeopts` contains exactly:

```
MENUSELECT_CFLAGS=OPTIONAL_API
```

`OPTIONAL_API` is `<defaultenabled>yes</defaultenabled>` (`build_tools/cflags.xml:39-44`) and
`BUILD_NATIVE` — the only other default-on flag (`:128-132`) — is switched off by the script and
filtered out of the sum anyway. So the checksum is reproducible from first principles:

```
$ echo "OPTIONAL_API" | md5sum | cut -c1-32
da6642af068ee5e6490c5b1d2cc1d238
```

which is precisely the value Part D.8 recorded. Three consequences:

- **`.claude/CLAUDE.local.md` was wrong** to call `da6642af068ee5e6490c5b1d2cc1d238` "specific to
  this host". It is specific to the *option set*. The Pi must produce the same string; if it does
  not, the menuselect flags drifted and that is the bug.
- **Sounds, XML documentation, the module `--enable`/`--disable` list, `--libdir` and every other
  `./configure` flag are irrelevant to it.** That is what makes B8 and B9 safe to fix.
- The `Check AST_BUILDOPT_SUM` ctest remains a *self*-consistency check only (**B4**): it greps
  the module for the string that came from the very headers it compiled against. The real check is
  §E.5 step 11.

### E.2 — Three blockers Phase 1 surfaced

| # | Blocker | Evidence | Effect |
| --- | --- | --- | --- |
| B8 | **The daemon and the module install to different directories.** | Asterisk's `astmoddir` is `${libdir}/asterisk/modules` (`configure.ac:41` → `makeopts.in:98`) and `libdir` defaults to `${exec_prefix}/lib`, so `--prefix=/usr` gives `/usr/lib/asterisk/modules`. chan-quectel installs to `lib/${CMAKE_LIBRARY_ARCHITECTURE}/asterisk/modules` (`src/CMakeLists.txt:44-51`) = `/usr/lib/aarch64-linux-gnu/asterisk/modules`. | The daemon would never see `chan_quectel.so`. Silent: no error, the module simply is not there. |
| B9 | **The script produces headers, not a usable daemon.** | It passes `--disable-xmldoc` and `--disable`s all six `CORE-SOUNDS-EN-*` / `MOH-OPSOUND-*` packages, plus `format_gsm`. | A daemon built from that tree has no prompt files, no music-on-hold and empty `core show application` output. |
| B10 | **`make install` leaves the daemon unrunnable as a service.** | It installs no systemd unit — `contrib/systemd/` is referenced by no Makefile target — and only `make config` installs anything, a SysV script (`Makefile:929-948`), which is the wrong artefact on trixie. It creates no `asterisk` user or group either (no `useradd`/`adduser` anywhere in `Makefile`, `configure.ac` or `contrib/`; there is no `--with-asterisk-user`). And `contrib/systemd/asterisk.service` is `Type=notify`, which needs `libsystemd` at `./configure` time (`configure.ac:2876`) — `contrib/scripts/install_prereq` never installs `libsystemd-dev`. | Without the unit and the account the daemon can only be run by hand as root; with `Type=notify` but no libsystemd it starts and is then killed at `TimeoutStartSec`. |

Two related traps found while validating the runbook, recorded here because they bite at exactly
this point and are *not* Asterisk-22 issues:

- **The driver's install prefix must be set at configure time, not install time.**
  `quectel.conf`'s destination is `${CMAKE_INSTALL_FULL_SYSCONFDIR}/asterisk`
  (`src/CMakeLists.txt:60-64`), an **absolute** path baked in by `INCLUDE(GNUInstallDirs)`
  (`CMakeLists.txt:272`). CMake does not relocate absolute destinations, so
  `cmake --install … --prefix=/usr` on a tree configured with the default prefix is not enough.
  Demonstrated in §E.4. The consequence is a hard load failure, not a warning:
  `reload_config()` returning non-zero makes `chan_quectel.c:1465-1468` log
  `Errors reading config file quectel.conf, Not loading module`.
- **`asterisk -rx` needs privileges.** `[files]` is commented out in
  `configs/samples/asterisk.conf.sample:149-154`, so the control socket is created under the
  daemon's own user with the default umask and a login user gets `EACCES`. Either use `sudo`, or
  set `astctlgroup`/`astctlpermissions` and join the group.

### E.3 — What changed in the repository

Only `tools/configure-asterisk-22.sh`, plus documentation. The script keeps its existing contract
exactly — positional `<src-tree>` / `<dest-tree>`, `ASTERISK_22_SRC`, `ASTERISK_22_BUILD`, `FORCE`,
`AST_DOWNLOAD_CACHE`, `AST_CODEC_ARGS`, the configured-tree assertion, and the discipline that
stdout carries nothing but the path.

**`AST_LIBDIR` — fixes B8.** The Debian multiarch triplet is autodetected once
(`dpkg-architecture -qDEB_HOST_MULTIARCH`, falling back to `${CC:-gcc} -print-multiarch`) and, when
non-empty, passed as `--libdir=/usr/lib/<triplet>`. `AST_LIBDIR=` (explicitly empty) restores
autoconf's `/usr/lib` for non-Debian hosts. Nothing else has to move:

- rpath is untouched — `configure.ac:1506-1509` reports "not needed" whenever `prefix` is `/usr`,
  and `/usr/lib/<triplet>` is already on Debian's loader path, so `libasteriskssl.so.1` and
  `libasteriskpj.so.2` resolve. `make install` runs `ld-cache-update` regardless (`Makefile:753`).
- `Makefile:650-663` computes `_oldlibdir` only when the libdir's basename is `lib` or `lib64`.
  A multiarch basename matches neither, so the lib/lib64 orphan check quietly stands down instead
  of misfiring — it is meaningless here anyway.

**`AST_PROFILE` — fixes B9.** `headers` (the default) reproduces the previous behaviour; `daemon`
changes three things and nothing else:

1. omits `--disable-xmldoc` — that flag is an `AC_SUBST`'d makeopts variable
   (`configure.ac:795-805`), not a `MENUSELECT_CFLAG`;
2. turns the six `--disable CORE-SOUNDS-EN-*` / `--disable MOH-OPSOUND-*` arguments into
   `--enable`. `EXTRA-SOUNDS-EN-*` stays off in both profiles;
3. re-enables `format_gsm`. The sound packages and the format modules that read them travel
   together: `.gsm` needs `format_gsm`, which the inherited CI list disabled, while `.wav` is
   `format_wav` and `.g722` is `format_pcm` (`formats/format_pcm.c:519-526`) — both already kept.
   `format_wav_gsm` stays disabled; it handles WAV49, which no sound package here ships.

`--disable BUILD_NATIVE` is **kept in both profiles**, deliberately: it is filtered out of the
checksum, and leaving `-march=native` off means a Pi 5 (Cortex-A76) build does not `SIGILL` on a
Pi 4 (Cortex-A72).

Every other argument — the whole `--without-*` list, the adaptive codec group, the module
selection — is shared, so `MENUSELECT_CFLAGS` is `OPTIONAL_API` under either profile and
`buildopts.h` is byte-identical between them. §E.4 verifies that rather than asserting it.

The stderr summary now also reports the profile and the resulting module directory, and the
`daemon` profile prints the `make`/`make install` follow-up. An unknown `AST_PROFILE` is a `die`.

Documentation touched: this chapter; `.claude/CLAUDE.md` §1 ("Finding the Asterisk headers");
`.claude/CLAUDE.local.md` (the two new variables, the corrected "specific to this host" sentence,
and the fact that `/home/quectel/asterisk-22-configured` now genuinely exists — the Part D.8
destination had been transient).

### E.4 — Dev-box verification actually run

All of it against **copies**; `/home/quectel/asterisk-22` is still byte-identical to the tarball
(`test ! -e .../include/asterisk/autoconfig.h` still succeeds, before and after).

**Both profiles, side by side.** The whole argument of §E.1, checked rather than asserted:

```
$ tools/configure-asterisk-22.sh /home/quectel/asterisk-22
AST_BUILDOPT_SUM: da6642af068ee5e6490c5b1d2cc1d238
Asterisk 22.11.0 configured in /home/quectel/asterisk-22-configured  (profile: headers)
Module directory: /usr/lib/x86_64-linux-gnu/asterisk/modules

$ AST_PROFILE=daemon tools/configure-asterisk-22.sh /home/quectel/asterisk-22 <dest>
AST_BUILDOPT_SUM: da6642af068ee5e6490c5b1d2cc1d238
Asterisk 22.11.0 configured in <dest>  (profile: daemon)
Module directory: /usr/lib/x86_64-linux-gnu/asterisk/modules

$ diff <hdr>/include/asterisk/buildopts.h <dest>/include/asterisk/buildopts.h
$ diff <(grep ^MENUSELECT_CFLAGS <hdr>/menuselect.makeopts) \
       <(grep ^MENUSELECT_CFLAGS <dest>/menuselect.makeopts)
```

Both diffs are **empty**, and both trees carry `MENUSELECT_CFLAGS=OPTIONAL_API`. The profiles do
differ where they are meant to:

| | headers | daemon |
| --- | --- | --- |
| `makeopts` `DISABLE_XMLDOC` | `yes` | `no` |
| `MENUSELECT_CORE_SOUNDS` | *(empty)* | `CORE-SOUNDS-EN-WAV CORE-SOUNDS-EN-GSM CORE-SOUNDS-EN-G722` |
| `MENUSELECT_MOH` | *(empty)* | `MOH-OPSOUND-WAV MOH-OPSOUND-GSM MOH-OPSOUND-G722` |
| `format_gsm` | in `MENUSELECT_FORMATS` (disabled) | absent (enabled) |
| `MENUSELECT_EXTRA_SOUNDS` | *(empty)* | *(empty)* |

Those categories are `positive_output="yes"` (`sounds/sounds.xml:1,274,304`), so a listed member is
an **enabled** one; `MENUSELECT_FORMATS` is the opposite polarity and lists what is off.

**The libdir fix (B8).** `makeopts` in the configured copy now reads `libdir = /usr/lib/x86_64-linux-gnu`
with `ASTMODDIR = ${libdir}/asterisk/modules`, and CMake independently reports
`Installing module on architecture-specific directory - lib/x86_64-linux-gnu/asterisk/modules`.
On the Pi both read `aarch64-linux-gnu`.

**The driver still builds and tests clean**:

```
$ cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/usr -DASTERISK_VERSION_NUM=220000 \
        -DAST_HEADER_DIR=/home/quectel/asterisk-22-configured/include -DBUILD_TESTING=ON
-- Asterisk version: 220000 [cached]
-- Looking for asterisk.h - found
-- Asterisk header directory: /home/quectel/asterisk-22-configured/include/
-- Getting AST_BUILDOPT_SUM - da6642af068ee5e6490c5b1d2cc1d238

$ cmake --build build -j$(nproc) && ctest --test-dir build
100% tests passed, 0 tests failed out of 4
```

**Four**, not five — `Check architecture-specific metadata` is gated on `CMAKE_CROSSCOMPILING`
(`src/CMakeLists.txt:95`) and does not run natively. The `## Verification` section below said
"five"; that is corrected. The only warnings are the pre-existing ones from Part D.8.

**The install-prefix trap, demonstrated.** Two builds of the same tree, each staged with `DESTDIR`:

```
# configured with -DCMAKE_INSTALL_PREFIX=/usr
/etc/asterisk/quectel.conf
/usr/lib/x86_64-linux-gnu/asterisk/modules/chan_quectel.so

# configured with the default prefix, then `cmake --install ... --prefix=/usr`
/usr/local/etc/asterisk/quectel.conf          <-- wrong, and fatal at load time
/usr/lib/x86_64-linux-gnu/asterisk/modules/chan_quectel.so
```

`--prefix` at install time relocates the module (a relative `DESTINATION`) but **not**
`quectel.conf`, whose `DESTINATION` is the absolute `${CMAKE_INSTALL_FULL_SYSCONFDIR}/asterisk`.
Hence `-DCMAKE_INSTALL_PREFIX=/usr` at *configure* time in §E.5 step 9.

**Sound prefetch works unprivileged.** The tarball ships only two of the six packages
(`sounds/asterisk-core-sounds-en-gsm-1.6.1.tar.gz`, `sounds/asterisk-moh-opsound-wav-2.03.tar.gz`);
the other four are fetched from `downloads.asterisk.org`. `sounds` is not in `SUBDIRS`
(`Makefile:280-282`), so under a plain `sudo make install` that download happens **as root**.
Doing it first as the normal user avoids root-owned files:

```
$ cd <dest> && make -C sounds all ASTTOPDIR="$PWD"
... asterisk-core-sounds-en-{wav,g722}, asterisk-moh-opsound-{gsm,g722} downloaded
```

~58 MB total, all six then present in `sounds/`.

**What could not be checked here.** No `asterisk` daemon, no `jq`, no `ninja`, no `lintian`, no
`clang-format` (Part D.4), and the box is x86-64 — so the daemon build, the runtime load, GCC 14
(**X6**) and packaging are all Pi-only. That is §E.5.

### E.5 — Raspberry Pi command list (Phase 1, step 5)

Everything below runs **on the Pi**, as the normal login user (member of `sudo`). It assumes
**§C.2 is done**: base packages installed, the repo cloned at `~/src/asterisk-chan-quectel` on
branch `asterisk-22` with the tag visible, and the verified `asterisk-22.11.0` tarball unpacked at
`~/src/asterisk-22`.

Run the blocks in order and check the expected output before moving on. Where a block says
*assert*, stop if it does not hold.

> **`~/src/asterisk-22` is still never configured or built in place.** Every command below that
> compiles anything runs in `~/src/asterisk-22-configured`, the copy step 4 creates.

#### 0. Space, and where the time goes

```sh
uname -m                        # aarch64
df -h /                         # need >= 10 GB free
free -m
nproc
```

Budget: the configured copy grows to ~2.5–4 GB during a full build (bundled pjproject 2.17, all
modules, XML docs), the sound tarballs add ~58 MB, and the install ~350–500 MB. Wall time is
dominated by pjproject (15–25 min) — roughly 45–70 min total on a Pi 5, 2–3 h on a Pi 4.

Pick the parallelism now and use the same `N` everywhere below:

```sh
N=$(( $(free -g | awk '/^Mem:/{print $2}') < $(nproc) ? $(free -g | awk '/^Mem:/{print $2}') : $(nproc) ))
[ "$N" -lt 1 ] && N=1
echo "using -j$N"
```

One GB of RAM per job is the rule of thumb. On a 2 GB Pi also do the `dphys-swapfile` bump from
§C.2 step 5.

#### 1. The packages Phase 0 did not cover

```sh
sudo apt install -y libsystemd-dev
```

**This must happen before step 4**, not after. `contrib/systemd/asterisk.service` is `Type=notify`,
which only works if Asterisk was linked against libsystemd — and `./configure` decides that
(`configure.ac:2876`). `contrib/scripts/install_prereq` does **not** install it, so §C.2 step 4 did
not bring it in. If you get here late, redo step 4 with `FORCE=1`.

Optional, only if you want those codecs in the daemon — the script demotes each to `--without-`
when `pkg-config` cannot see it (none is needed by `chan_quectel`):

```sh
sudo apt install -y libopus-dev libopusfile-dev libogg-dev libspeexdsp-dev
```

Also worth having on a modem host:

```sh
sudo apt install -y usb-modeswitch socat
```

#### 2. Pick up the updated driver repository

```sh
cd ~/src/asterisk-chan-quectel
git status --short                                          # must be empty
git pull --ff-only
git describe --abbrev=6 --dirty --match "v*" --long --tags   # assert: starts with v2026.08.30-
```

The tag gate at `CMakeLists.txt:48-69` fires on **every** plain `cmake -S . -B`, so assert it here
rather than discovering it in step 9. If it prints `fatal: No names found`, run
`git fetch --tags`, and only then fall back to `cmake -P make-release-tag.cmake` on a clean tree.

#### 3. A download cache

```sh
mkdir -p ~/.cache/asterisk-src
```

`third-party/{pjproject,jansson,libjwt}` are fetched during `./configure`, and the sound tarballs
during the build. Pointing both at a cache means a later `FORCE=1` reconfigure does not
re-download, and makes an offline rebuild possible.

#### 4. Configure the copy — daemon profile

```sh
cd ~/src/asterisk-chan-quectel
AST_INC=$(AST_PROFILE=daemon AST_DOWNLOAD_CACHE=~/.cache/asterisk-src \
          tools/configure-asterisk-22.sh ~/src/asterisk-22)
echo "$AST_INC"
```

Assert, on stderr:

```
AST_BUILDOPT_SUM: da6642af068ee5e6490c5b1d2cc1d238
Asterisk 22.11.0 configured in /home/<user>/src/asterisk-22-configured  (profile: daemon)
Module directory: /usr/lib/aarch64-linux-gnu/asterisk/modules
```

and `$AST_INC` = `~/src/asterisk-22-configured/include`.

- **A different checksum means the menuselect flags drifted.** It is derived from
  `MENUSELECT_CFLAGS=OPTIONAL_API` and nothing else (§E.1) — do not proceed; diff
  `menuselect.makeopts` against this document.
- **`Already configured: … (set FORCE=1 to redo)` means nothing was reconfigured.** The script
  cannot tell which profile built an existing destination. Any re-run — after installing
  `libsystemd-dev`, after changing profile — needs `FORCE=1 AST_PROFILE=daemon …`.
- `./configure` needs network here (pjproject). Offline, stage the three tarballs into
  `~/.cache/asterisk-src` first.

Confirm libsystemd was actually found, *before* you rely on `Type=notify`:

```sh
grep -E '^HAVE_SYSTEMD|^SYSTEMD_LIB' ~/src/asterisk-22-configured/makeopts
grep -E 'HAVE_SYSTEMD' ~/src/asterisk-22-configured/include/asterisk/autoconfig.h
```

Expect `HAVE_SYSTEMD=1` and `SYSTEMD_LIB=-lsystemd` in `makeopts`, and
`#define HAVE_SYSTEMD 1` in `autoconfig.h`.

`PBX_SYSTEMD` is the *autoconf* variable name (`configure.ac:2873`); it never appears in
`makeopts`, which substitutes it under the `HAVE_` name — `makeopts.in:260` is
`HAVE_SYSTEMD=@PBX_SYSTEMD@`. `autoconfig.h` is the one that matters at compile time: `main/io.c`
guards both `#include <systemd/sd-daemon.h>` and the body of `ast_sd_notify()` with
`#ifdef HAVE_SYSTEMD`, so without it `ast_sd_notify()` is a stub returning 0 and `READY=1` is
never sent.

If `HAVE_SYSTEMD` is `0` (or `autoconfig.h` still has `/* #undef HAVE_SYSTEMD */`), install
`libsystemd-dev` and redo step 4 with `FORCE=1`.

#### 5. Prefetch the sounds as yourself

```sh
cd ~/src/asterisk-22-configured
make -C sounds all ASTTOPDIR="$PWD"
ls -1 sounds/*.tar.gz | wc -l        # 6
```

The tarball ships only 2 of the 6 packages; the rest come from `downloads.asterisk.org`. `sounds`
is not in `SUBDIRS` (`Makefile:280-282`), so skipping this makes `sudo make install` download them
**as root** and leave root-owned files in your cache.

#### 6. Create the service account before installing

```sh
sudo adduser --system --group --home /var/lib/asterisk --no-create-home \
             --disabled-login --gecos "Asterisk PBX" asterisk
sudo usermod -aG dialout,audio asterisk
id asterisk
```

Asterisk's build system creates no user and has no `--with-asterisk-user`; nothing in `make install`
does this for you. `dialout` is the modem TTYs (`src/tty.c` opens them with `TIOCEXCL` + `flock`);
`audio` is only needed in UAC mode, but costs nothing.

#### 7. Build and install the daemon

```sh
cd ~/src/asterisk-22-configured
make -j"$N"
sudo make install
sudo make samples OVERWRITE=y
sudo make install-logrotate
```

- `make install` depends on `_all`, so build explicitly first with your chosen `-j` — otherwise it
  builds serially under `sudo`.
- **Not `make config`.** That installs the SysV script from `contrib/init.d/rc.debian.asterisk`
  and runs `update-rc.d` (`Makefile:940-948`) — the wrong artefact on trixie. Step 9 installs the
  systemd unit instead.
- **Not `make install-headers`.** It would recreate `/usr/include/asterisk`, exactly the fallback
  Part D.4 deliberately removed; the driver takes its headers from `$AST_INC`.
- `OVERWRITE=y` on `make samples` is belt-and-braces. On a fresh `/etc/asterisk` the file copying
  is identical either way, but the path-rewriting `sed` in `INSTALL_CONFIGS` (`Makefile:782-800`)
  runs **only** under `OVERWRITE=y`, and that is what makes `asterisk.conf`'s `astmoddir` line
  agree with the multiarch directory. It is inert as shipped — the stanza is a template,
  `[directories](!)` — but leaving a stale `/usr/lib/asterisk/modules` in there is a trap for
  whoever later removes the `(!)`. On a **re-install** `OVERWRITE=y` renames your existing configs
  to `*.old`; back up `/etc/asterisk` first.

Then assert the daemon and the module agree on where modules live:

```sh
grep '^astmoddir' /etc/asterisk/asterisk.conf     # => /usr/lib/aarch64-linux-gnu/asterisk/modules
ls -d /usr/lib/aarch64-linux-gnu/asterisk/modules
command -v asterisk; readlink -f /usr/sbin        # note whether /usr/sbin is merged into /usr/bin
```

#### 8. Ownership and `asterisk.conf`

```sh
sudo chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk \
                                /var/spool/asterisk /var/cache/asterisk
sudo chown -R root:asterisk /etc/asterisk
sudo chmod -R o-rwx /etc/asterisk
```

`/var/run/asterisk` is deliberately **not** in that list — it lives on tmpfs and is recreated on
every start by `RuntimeDirectory=asterisk` in step 9.

Edit `/etc/asterisk/asterisk.conf`, in `[options]`:

```ini
runuser  = asterisk
rungroup = asterisk
```

and, so that `asterisk -rx` works without `sudo`, in `[files]` — **uncommenting the section
header itself, not just the keys**:

```ini
[files]
astctlpermissions = 0660
astctlowner       = asterisk
astctlgroup       = asterisk
```

then

```sh
sudo usermod -aG asterisk "$USER"      # takes effect at your next login
```

Both stanzas ship commented out: `runuser`/`rungroup` at `asterisk.conf.sample:79-80`, and the
whole `[files]` block — **header included** — at `:149-154`. That header is the trap. Asterisk
reads these three keys only through `ast_variable_browse(cfg, "files")` (`main/options.c:249-258`),
so with `;[files]` left commented the uncommented keys are parsed as part of the preceding
`[options]` section, where nothing matches them and they are dropped without a warning.
`ctl_perms`, `ctl_owner` and `ctl_group` then stay empty (`main/options.c:129-148` initialises
only `.ctl_file`) and `ast_makesocket()` skips both fixups — `chown()` gets `uid = gid = -1` and
the `chmod()` is guarded by `!ast_strlen_zero()` (`main/asterisk.c:1666-1692`).

`/var/run/asterisk/asterisk.ctl` is then left with whatever mode a bound AF_UNIX socket inherits
from the daemon's umask — `srwxr-xr-x asterisk:asterisk` under systemd's default `UMask=0022`.
Group `asterisk` can read it but not write it, and connecting to a unix socket requires **write**
permission, so every `asterisk -rx` from your login shell fails with `Unable to connect to remote
asterisk` even when `id` shows you in the group and step 8's ownership is correct. Diagnose with
`ls -l /var/run/asterisk/asterisk.ctl`: `srw-rw----` is right, `srwxr-xr-x` means the `[files]`
header is still commented out. Until you log out and back in, prefix the CLI commands below with
`sudo`.

#### 9. systemd unit

```sh
sudo install -m 644 ~/src/asterisk-22-configured/contrib/systemd/asterisk.service \
                    /etc/systemd/system/asterisk.service
sudo sed -i -e 's|^#RuntimeDirectory=asterisk|RuntimeDirectory=asterisk|' \
            -e "s|^ExecStart=.*asterisk |ExecStart=$(command -v asterisk) |" \
            -e "s|^ExecReload=.*asterisk |ExecReload=$(command -v asterisk) |" \
            /etc/systemd/system/asterisk.service
grep -E '^(ExecStart|ExecReload|RuntimeDirectory|User|Group|Type)=' /etc/systemd/system/asterisk.service
sudo systemctl daemon-reload
sudo systemctl enable --now asterisk
```

Nothing in Asterisk's build system installs this file — `contrib/systemd/` is referenced by no
Makefile target — so the copy is mandatory. The shipped unit hardcodes `/usr/sbin/asterisk`
(`contrib/systemd/asterisk.service:16-17`) while the script configures `--sbindir=/usr/bin`, and
trixie does **not** merge `/usr/sbin` into `/usr/bin` — `readlink -f /usr/sbin` in step 7 prints
`/usr/sbin`, so the two are different directories and `/usr/sbin/asterisk` does not exist. The
`sed` above is therefore load-bearing, not cosmetic: without it `systemctl start` fails with
`status=203/EXEC`. `RuntimeDirectory` ships commented out, and without it `/var/run/asterisk`
does not exist on a tmpfs `/run`.

#### 10. Verify the daemon

```sh
systemctl status asterisk --no-pager
journalctl -u asterisk -b --no-pager | tail -40
asterisk -rx 'core show settings'  | grep -Ei 'version|build options|module directory|user|group'
asterisk -rx 'module show like pjsip' | tail -3
ls -l /var/log/asterisk/
asterisk -rx 'logger show channels'
```

Assert: version `22.11.0`, `ABI related Build Options: OPTIONAL_API`, and a module directory of
`/usr/lib/aarch64-linux-gnu/asterisk/modules`. A `Type=notify` unit that starts and is then killed
after ~90 s means `HAVE_SYSTEMD` was `0` at step 4 — go back and reconfigure with `FORCE=1`.

The only log file `make samples` leaves enabled is `messages.log`; `app_queue` adds `queue_log` when
it loads. **There is no `/var/log/asterisk/full`** — the extensionless names are pre-13, and today's
sample is `;full.log => …`, shipped commented out (`configs/samples/logger.conf.sample:174-177`,
identical in 20.21.0 and 22.11.0; `contrib/scripts/asterisk.logrotate` rotates `*.log`, `queue_log`
and `mmlog` only). For the driver debugging in steps 12–14, uncomment that line in
`/etc/asterisk/logger.conf` and run `asterisk -rx 'logger reload'` — the file appears on reload, not
at daemon start.

#### 11. Build the driver against that same tree

Independent of steps 6–10: this needs only `$AST_INC`, not a running daemon. If `$AST_INC` is no
longer set in your shell, it is `~/src/asterisk-22-configured/include`.

```sh
cd ~/src/asterisk-chan-quectel
cmake -S . -B build \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DASTERISK_VERSION_NUM=220000 \
      -DAST_HEADER_DIR="$AST_INC" \
      -DBUILD_TESTING=ON \
      -DCLANG_FORMAT=/usr/bin/clang-format-18
cmake --build build -j"$N" 2>&1 | tee /tmp/chan-quectel-build.log
ctest --test-dir build
```

- **`-DCMAKE_INSTALL_PREFIX=/usr` is not optional and cannot be deferred to install time.**
  `quectel.conf`'s destination is absolute (§E.2, demonstrated in §E.4); get this wrong and the
  file lands in `/usr/local/etc/asterisk` and the module refuses to load.
- `-DCLANG_FORMAT=…` is the **B6** workaround until Phase 2 step 9 — trixie's unversioned
  `clang-format` is 19 and `ClangFormatFindAndCheck(18)` rejects it.
- Expect `4 tests passed` — `Check architecture-specific metadata` is cross-compile-only.
  `Check library dependencies` should report only `libasound`, `libsqlite3`, `libc`, `libgcc_s`
  and `ld-linux-aarch64.so.1`; anything else is a one-line `ALLOWED_LIBS` fix in
  `cmake/test/needed-libs.cmake`, not a porting problem.
- **X6, the real point of building here:** GCC 14 promotes `-Wimplicit-function-declaration`,
  `-Wincompatible-pointer-types`, `-Wint-conversion` and `-Wreturn-mismatch` to errors. Skim the
  log — `grep -E 'warning|error' /tmp/chan-quectel-build.log`. **None of those four may appear.**
  What does appear is one benign warning, plus one that is toolchain-dependent:

  | Warning | Source | Verdict |
  | --- | --- | --- |
  | `alsa/global.h:30: #warning "use #include <alsa/asoundlib.h>…" [-Wcpp]` | `src/cli.c:11` includes `<alsa/global.h>` directly for the version macros; alsa-lib nags by design | expected, cosmetic, unrelated to Asterisk |
  | `memmem.c:55: -Wdiscarded-qualifiers` | `return memchr(l, (int)*cs, l_len);` | **may or may not appear.** GCC 15 emits it, trixie's GCC 14 does not. `memmem.c` is compiled either way — its `#ifndef HAVE_MEMMEM` guard is line 1, before anything includes `config.h`, so the fallback is never actually compiled out |

  Note that `grep -E 'warning|error'` also matches the *filename* in
  `[ 72%] Building C object …/error.c.o`. That is not an error.

  Historical: this step also used to emit four ``‘struct ast_frame’/‘struct ast_str’ declared
  inside parameter list`` warnings from `asterisk/codec.h` and `asterisk/format.h`. Cause was
  `src/dc_config.c:4` opening with `<asterisk/callerid.h>` instead of `"ast_config.h"` — the only
  `.c` in `src/` that pulled an Asterisk header before `ast_config.h`, so `callerid.h:48 →
  format.h:26 → codec.h` was reached before `<asterisk.h>` had declared either tag. Inert (nothing
  in `src/` calls `ast_codec_samples_count()` or `ast_format_generate_sdp_fmtp()`) and **not** an
  Asterisk-22 regression — `format.h` is byte-identical between 20.21.0 and 22.11.0, and the two
  `codec.h` prototypes sit at `:68` and `:188` in 20 against `:68` and `:190` in 22, the offset
  being the added `quality` field. Fixed by putting `"ast_config.h"` first in `dc_config.c`; if
  the warnings reappear, that include order has regressed.

```sh
readelf -hW build/src/chan_quectel.so | grep -E 'Machine|Type'   # AArch64, DYN
```

#### 12. Prove B4 — the check `ctest` structurally cannot make

`Check AST_BUILDOPT_SUM` only greps the module for the string that came from the headers it was
compiled against; it can never detect a mismatch with the *installed* daemon. Compare them
directly — and note that `core show settings` prints build option **names**, never the checksum
(`main/asterisk.c:502-503`), so the daemon's value has to come from the binary or the tree:

```sh
grep -Eao '[0-9a-f]{32}' build/src/chan_quectel.so | sort -u
sed -n 's/.*AST_BUILDOPT_SUM.*"\([0-9a-f]*\)".*/\1/p' \
    ~/src/asterisk-22-configured/include/asterisk/buildopts.h
grep -Fac da6642af068ee5e6490c5b1d2cc1d238 "$(command -v asterisk)"
```

The first two must print `da6642af068ee5e6490c5b1d2cc1d238`; the third must print a non-zero count.

The daemon keeps its own copy in `static char buildopt_sum[33] = AST_BUILDOPT_SUM;`
(`main/loader.c:147`), so the string really is in the binary — but do **not** look for it with
`grep -Eao '[0-9a-f]{32}' … | sort -u | head`. The daemon also contains long runs of decimal
digits (float-conversion tables), which are valid `[0-9a-f]{32}` matches and sort *ahead* of any
sum beginning with a letter, so `head` shows only those and hides the real answer. Grep for the
expected value instead.

#### 13. Install and load the module

```sh
sudo cmake --install build --component chan-quectel
ls -l /usr/lib/aarch64-linux-gnu/asterisk/modules/chan_quectel.so
ls -l /etc/asterisk/quectel.conf
```

No `--prefix` here: it was fixed at configure time in step 11. Both files must exist, and the
module's directory must be the one step 10 reported.

`modules.conf.sample:8` is `autoload=yes`, so a restart loads the module by itself and a subsequent
`module load` would answer *"Module chan_quectel.so already exists"*. Load it explicitly instead,
without restarting:

```sh
sudo asterisk -rx 'module load chan_quectel.so'
asterisk -rx 'module show like chan_quectel'
asterisk -rx 'core show channeltype Quectel'
asterisk -rx 'core show taskprocessors like chan-quectel'
asterisk -rx 'quectel show devices'
```

A mismatch of the kind step 12 guards against surfaces right here, as Asterisk refusing the module
(`main/loader.c:1836`): *"Module was not compiled with the same compile-time options"*.

#### 14. Point it at the modem

`quectel.conf` ships a **live** `[quectel0]` with `audio=/dev/ttyUSB1` and `data=/dev/ttyUSB2`
(`quectel.conf:44-46`), so the module loads but the device stays down if your enumeration differs.

```sh
lsusb                                       # is the modem on the bus at all?
ls -l /dev/ttyUSB* /dev/ttyACM* 2>&1        # did a serial driver bind?
dmesg | grep -iE 'option|qcserial|cdc_acm|ttyUSB|ttyACM' | tail -20
sudoedit /etc/asterisk/quectel.conf
sudo asterisk -rx 'quectel reload now'
asterisk -rx 'quectel show devices'         # the device should reach Free
```

`/dev/serial/by-id/` is **not** a directory you can count on. udev creates it lazily — it exists
only once something has put a symlink in it, and systemd's `60-serial.rules` adds the `by-id` link
only when `ID_SERIAL` is non-empty. Modems whose firmware ships an empty USB iSerial string get a
`/dev/serial/by-path/` link and no `by-id` one, so `ls -l /dev/serial/by-id/` answers `No such file
or directory` on a perfectly healthy setup. Read it as a diagnostic, not a step:

| `lsusb` | `/dev/ttyUSB*` | `/dev/serial/by-id/` | Meaning |
| --- | --- | --- | --- |
| no modem | — | — | hardware, power, or USB composite mode — nothing to configure yet |
| modem | none | — | no `option`/`qcserial`/`cdc_acm` bind; check `dmesg` and ModemManager below |
| modem | present | missing | normal; the modem reports no iSerial — use `by-path` or `tools/udev/` |
| modem | present | present | stable names available |

```sh
ls -l /dev/serial/by-path/                  # exists whenever ID_PATH does
udevadm info -q property -n /dev/ttyUSB2 | grep -E 'ID_SERIAL|ID_PATH|ID_VENDOR'
```

The plain `/dev/ttyUSBn` paths in `quectel.conf` work regardless; they are just not stable across
reboots or re-plugs.

**Disable ModemManager first** — it opens `/dev/ttyUSB*` on hotplug and will lose the race against
`TIOCEXCL` + `flock`:

```sh
sudo systemctl disable --now ModemManager
```

Optional, for stable names: the IMEI/IMSI udev rules in `tools/udev/` (they need `socat`) create
`/dev/modem/by-imei/*` symlinks — see `tools/udev/README.md`.

#### 15. Smoke test

With a modem attached and registered: place and answer a call (exercises `channel_tech` and the
audio path), send an SMS with `QUECTEL_SEND_SMS`, and confirm an inbound SMS reaches the `sms`
extension (`pdu.c` → `smsdb.c` → `channel_start_local_json()`). See `README.md` for the dialplan
surface.

#### 16. If something goes wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Module was not compiled with the same compile-time options` | daemon and module came from different option sets | step 12; rebuild the driver against the tree the daemon was built from |
| `module load` says *"Module not found"* | the `.so` is not in the daemon's `astmoddir` | compare step 13's `ls` with step 10's module directory — this is **B8** |
| `Errors reading config file quectel.conf, Not loading module` | `quectel.conf` in `/usr/local/etc/asterisk` | `-DCMAKE_INSTALL_PREFIX=/usr` was missing at *configure* time; redo step 11 |
| service starts, is killed ~90 s later | `Type=notify` without libsystemd | `HAVE_SYSTEMD` was `0` in `makeopts`; install `libsystemd-dev`, redo step 4 with `FORCE=1`, rebuild |
| `Unable to connect to remote asterisk` from `asterisk -rx` | control-socket permissions | step 8's `[files]` stanza, then log out and back in; `sudo` meanwhile |
| `Permission denied` on `/dev/ttyUSB*` | `asterisk` not in `dialout`, or ModemManager holds the port | step 6 and step 14 |
| `/dev/serial/by-id/`: *No such file or directory* | udev made no `by-id` link — usually no modem enumerated, no serial driver bound, or an empty USB iSerial | step 14's table; `by-id` is optional, `/dev/ttyUSBn` still works |
| `./configure` hangs at third-party | no network for pjproject | `AST_DOWNLOAD_CACHE` with the tarballs staged |
| step 4 prints `Already configured` and changes nothing | destination exists | re-run with `FORCE=1` |
| `Git - unable to describe` from CMake | tag missing after clone | `git fetch --tags`, else `cmake -P make-release-tag.cmake` (**B1**) |
| `[dev][AT+CSCS] ⍻ No UCS-2 encoding support`, device stuck at `Not initialized` | **SIM not seated** — init aborts before it ever reaches `AT+CPIN?`, so it blames the charset | reseat the SIM; confirm with `AT+CPIN?` / `AT+QSIMSTAT?` on the raw TTY (**E.8.2**) |
| daemon SEGVs on `quectel show device state` | out-of-range enum read — fixed in `src/mutils.h` | **E.8.1**; if it recurs, rebuild, the installed `.so` predates the fix |

Rollback: `sudo systemctl disable --now asterisk`, `sudo rm /etc/systemd/system/asterisk.service`,
`cd ~/src/asterisk-22-configured && sudo make uninstall`. `make uninstall-all` additionally
`rm -rf`s `/etc/asterisk`, `/var/lib/asterisk` and the spool — do not run it casually.

### E.6 — Status after Phase 1

| Blocker | State | Closed by |
| --- | --- | --- |
| **B1** no git tag | Fixed | Phase 0 |
| **B2** unconfigured tree → `Asterisk header not found.` | Fixed in practice; the misleading *message* is still Phase 2, step 7 | Part D.6 |
| B3 `ASTERISK_VERSION_NUM` defaults to `180000` | open, still masked | Phase 2, step 6 |
| **B4** `AST_BUILDOPT_SUM` self-consistency only | **Closed by construction on the dev box** (§E.4) — the daemon half is §E.5 steps 4/12 on the Pi. The *ctest* remains self-consistency-only, by design | Phase 1, §E.1/§E.4 |
| B5 missing `build-arm64` / `package-arm64` presets | open — §E.5 step 13 sidesteps it with a direct `cmake --install` | Phase 3, step 12 |
| B6 `clang-format` found only under the bare name | open (workaround `-DCLANG_FORMAT=/usr/bin/clang-format-18`, §E.5 step 11) | Phase 2, step 9 |
| **B7** Asterisk tree has no `.version` | Fixed | tree re-baseline (Part D.3) |
| **B8** daemon and module install to different directories | **Fixed** — `AST_LIBDIR` → `--libdir=/usr/lib/<triplet>` | Phase 1, §E.3 |
| **B9** script produces headers, not a usable daemon | **Fixed** — `AST_PROFILE=daemon` | Phase 1, §E.3 |
| **B10** `make install` leaves the daemon unrunnable as a service | **Documented, not automated** — §E.5 steps 1, 6, 8, 9. Nothing in the repo installs a unit or creates the account, and nothing here changes that | Phase 1, §E.5 |
| P1–P4 packaging | open | Phase 3 |
| P5, P6 | verified already correct — do not "fix" | — |
| X1, X2 docker | open | Phase 4 |
| **X3** menuselect list invalid for 22 | Fixed | Part D.6 |
| X4 OpenWRT | open | Phase 5 |
| X5 README | open | Phase 6 |
| X6 GCC 14 promoted warnings | **still unverified** — needs the real build at §E.5 step 11 | §E.5, step 11 |

Two corrections to earlier text, both made:

- **`## Verification` step 3 said "All five tests must pass".** It is **four** on a native build;
  `Check architecture-specific metadata` is gated on `CMAKE_CROSSCOMPILING` (`src/CMakeLists.txt:95`).
- **`## Verification` step 6 asked to read the checksum out of `core show settings`.** That command
  prints build option *names* (`main/asterisk.c:502-503`), never the md5. §E.5 step 12 has the
  working comparison.

`src/` now carries two changes on this branch — the `ast_config.h` include-order fix in
`dc_config.c` and the `enum2str_def()` crash fix in `mutils.h` (**E.8**) — and there is still no
`#if ASTERISK_VERSION_NUM` guard anywhere.

### E.7 — How to re-check this chapter

```sh
cd /home/quectel/asterisk-chan-quectel

# the reference trees are still pristine
test ! -e /home/quectel/asterisk-20/include/asterisk/autoconfig.h
test ! -e /home/quectel/asterisk-22/include/asterisk/autoconfig.h && echo pristine

# the checksum is derivable, not observed
echo "OPTIONAL_API" | md5sum | cut -c1-32      # da6642af068ee5e6490c5b1d2cc1d238

# the two profiles agree on everything the checksum sees
AST_PROFILE=daemon FORCE=1 tools/configure-asterisk-22.sh /home/quectel/asterisk-22 /tmp/ast22-d
diff /home/quectel/asterisk-22-configured/include/asterisk/buildopts.h \
     /tmp/ast22-d/include/asterisk/buildopts.h                          # empty
diff <(grep ^MENUSELECT_CFLAGS /home/quectel/asterisk-22-configured/menuselect.makeopts) \
     <(grep ^MENUSELECT_CFLAGS /tmp/ast22-d/menuselect.makeopts)        # empty
grep -E '^(DISABLE_XMLDOC)' /home/quectel/asterisk-22-configured/makeopts /tmp/ast22-d/makeopts
                                                                        # yes / no

# the libdir fix
grep -E '^libdir' /home/quectel/asterisk-22-configured/makeopts         # /usr/lib/<triplet>

# the install-prefix trap
cmake -S . -B /tmp/b -DASTERISK_VERSION_NUM=220000 \
      -DAST_HEADER_DIR=/home/quectel/asterisk-22-configured/include >/dev/null
cmake --build /tmp/b -j"$(nproc)" >/dev/null
DESTDIR=/tmp/stage cmake --install /tmp/b --component chan-quectel --prefix=/usr >/dev/null
find /tmp/stage -type f          # quectel.conf under /usr/local/etc - the failure mode
```


### E.8 — Runtime defects found on the Pi (§E.5 step 14)

Two issues surfaced the first time the module met a real modem — an EC25-EUX on a Raspberry Pi
running the Asterisk 22.11.0 daemon built by §E.5. Neither is an Asterisk-20-vs-22 problem. One is
a genuine driver defect, now fixed (E.8.1); the other turned out to be a badly seated SIM whose
symptom pointed convincingly at the driver and then at the modem firmware (E.8.2).

#### E.8.1 — `enum2str_def()` reads out of bounds — daemon SEGV (**fixed**)

`quectel show device state <dev>` crashed the whole daemon whenever the device had never
registered on the network:

```
#0  enum2str_def (value=4294967295, names=<gsm_states>, items=9, def="Unknown") at src/mutils.h:22
#1  gsm_regstate2str (gsm_reg_status=-1) at src/helpers.c:645
#2  cli_show_device_state at src/cli.c:202
#3  ast_cli_command_full at cli.c:3136
```

Cause: `S_COR(a, b, c)` **does not short-circuit**. It expands to

```c
#define S_COR(a, b, c) ({typeof(&((b)[0])) __x = (b); (a) && !ast_strlen_zero(__x) ? (__x) : (c);})
```

(`include/asterisk/strings.h:87`), so `__x = (b)` is evaluated before `a` is ever tested. The old
body was `return S_COR(value < items, names[value], def);`, which therefore read `names[value]`
unconditionally. `gsm_regstate2str()` declares `int` but the parameter is `unsigned`, so
`pvt->gsm_reg_status = -1` (`chan_quectel.c:155`, and again at `:1132`) arrives as `4294967295` and
the read lands ~34 GB past the array.

**Not a version problem.** `strings.h` is byte-identical between 20.21.0 and 22.11.0 (Part A.1), so
this crashes identically on Asterisk 20. It is a latent bug in the driver that only fires when a
caller passes an out-of-range value, and `gsm_reg_status` is the only initialiser in `src/` that
does — `pvt->act` starts at `0` (`chan_quectel.c:157`), inside `sys_act2str()`'s range.

Fixed in `src/mutils.h` by bounds-checking before indexing; `S_OR` preserves the previous
empty-string-falls-back-to-default behaviour:

```c
if (value >= items) {
    return def;
}
return S_OR(names[value], def);
```

One fix covers every caller — `enum2str()` delegates here, as do `gsm_regstate2str()`,
`gsm_regstate2str_json()`, `sys_act2str()` and the rest of `helpers.c`.

The other seven `S_COR` sites in `src/` were checked and are safe: only `cli.c:142` has a
non-trivial second argument, `ast_describe_caller_presentation()`, and that is a linear search over
`pres_types[]` returning `"unknown"` for any unmatched value, negatives included — an unnecessary
call, not a crash.

Reproduced and verified on the dev box, no modem needed:

```sh
# old body → SIGSEGV; new body → "DEF"
printf '%s\n' 'static const char* const n[] = {"zero","one",""};' \
  'enum2str_def((unsigned)-1, n, 3, "DEF");'
```

#### E.8.2 — `AT+CSCS="UCS2"` fails when the SIM is not seated (**resolved — hardware**)

```
[quectel0][AT+CSCS] ⍻ No UCS-2 encoding support
[quectel0] Fail to handle response
```

**Root cause: the SIM card was not properly seated in its holder.** Reseating it made
`AT+CSCS="UCS2"` succeed and initialisation complete. Not a driver defect and not a firmware
defect — but the symptom pointed at both, so it is recorded here in full.

Why it looked like a UCS-2 problem. `AT+CSCS="UCS2"` is the 4th command of
`at_enqueue_initialization()` (`at_command.c:162`). Its error case does `goto e_return`
(`at_response.c:693-695`), `at_response()` returns −1, `response_taskproc()` logs *Fail to handle
response*, and the monitor thread tears the device down and restarts it. So the device sat at
`Not initialized` (`connected = 1`, `initialized = 0`, `chan_quectel.c:962-971`) and restarted every
few seconds, which is what kept re-exposing E.8.1.

The misdiagnosis was reinforced by two things that both looked like firmware faults:

```
AT+CSCS=?        → +CSCS: ("IRA","GSM","UCS2")   OK      ← charset advertised as supported
AT+CSCS="UCS2"   → ERROR                                  ← …but every write form rejected
AT+CSCS=UCS2     → ERROR
AT+CSCS="GSM"    → ERROR
AT+CMEE=2        → OK                                     ← and errors stayed bare afterwards
ATI              → Quectel / EC25 / EC25EUXGAR08A19M1G
AT+QGMR          → EC25EUXGAR08A19M1G_A0.200.A0.200
```

A test command that lists a charset the write command then refuses reads as a firmware bug. It is
not; on this EC25-EUX build the `AT+CSCS=` write fails while the SIM is absent or badly seated.

**Diagnostic lesson: `AT+CPIN?` is the check that would have caught this, and the driver never
reaches it.** It sits at `at_command.c:177`, eight commands after the CSCS that aborts the chain.
Anything that kills init before `CMD_AT_CPIN` therefore reports the *symptom* command rather than
the SIM. When a device is stuck at `Not initialized`, query the SIM on the raw TTY first:

```
AT+CPIN?     → +CPIN: READY
AT+QSIMSTAT? → +QSIMSTAT: 0,1     (second field 1 = SIM inserted)
AT+CCID
```

Two driver-side observations, both recorded and **not** acted on:

- **The fatal abort is disproportionate.** `from_ucs2()` is called in only three places — SMSC from
  `+CSCA` (`at_response.c:1334`), network names from `+QSPN` (`:2637,2643`), and USSD text
  (`:1866,1884`). SMS runs in PDU mode (`AT+CMGF=0`, `at_command.c:161`) and carries its own
  encoding; voice is unaffected. Losing UCS-2 degrades three display strings, yet
  `at_response.c:693` refuses to bring the device up at all.
- **The message misleads.** *"No UCS-2 encoding support"* named the wrong subsystem for a seating
  fault. Either moving `CMD_AT_CPIN` ahead of `CMD_AT_CSCS`, or having the CSCS error handler
  mention the SIM, would have cut this diagnosis short.


---

## Verification

Run in order; each step gates the next.

0. **The reference tree is still pristine** — it must never be configured in place:
   ```sh
   test ! -e /home/quectel/asterisk-22/include/asterisk/autoconfig.h && echo pristine
   ```
1. **Headers exist in the configured copy:**
   ```sh
   AST_INC=$(tools/configure-asterisk-22.sh /home/quectel/asterisk-22)
   ls "${AST_INC}"/asterisk/{autoconfig.h,buildopts.h}
   grep AST_BUILDOPT_SUM "${AST_INC}"/asterisk/buildopts.h
   ```
2. **Configure:**
   ```sh
   cmake -S . -B build -DASTERISK_VERSION_NUM=220000 -DAST_HEADER_DIR="${AST_INC}"
   # or, once Phase 2 lands: cmake -P make-build-dir.cmake rpi64 220000
   ```
   Assert `Looking for asterisk.h - found`, `Asterisk version: 220000 [header]` (not `[default]`),
   `Asterisk header directory:` naming the copy — **never** `/usr/include/` — and
   `Getting AST_BUILDOPT_SUM - <32 hex>`, not `unknown`.
3. **Full reproducible build + tests:**
   ```sh
   ./get-source-date-epoch.sh > .env
   ./get-build-flags.sh rpi64 > CMakeUserPresets.json
   ./dotenv.sh .env cmake -P make-build-dir.cmake rpi64 220000
   ./dotenv.sh .env cmake -P build-chan-quectel.cmake rpi64
   ctest --preset rpi64
   ```
   All four tests must pass — `Check architecture-specific metadata` is gated on
   `CMAKE_CROSSCOMPILING` (`src/CMakeLists.txt:95`) and does not run natively. In particular
   **`Check AST_BUILDOPT_SUM`** and
   **`Check library dependencies`** (confirms only `libasound`, `libsqlite3`, `libc`,
   `libgcc_s`, `ld-linux-aarch64.so.1` are `NEEDED`).
4. **Compiler check (X6):** the build must be warning-free under GCC 14 with `-Wall`. Treat any
   `-Wincompatible-pointer-types` / `-Wint-conversion` as a hard failure — they are errors by
   default in GCC 14.
5. **ELF sanity:** `readelf -hW build/src/chan_quectel.so` reports `Machine: AArch64`,
   `Type: DYN`.
6. **Checksum agreement with the running daemon** — the check the ctest cannot do. Note that
   `core show settings` prints build option *names*, never the md5 (`main/asterisk.c:502-503`),
   so the daemon's value has to come from its binary or its tree:
   ```sh
   SUM=$(grep -Eao '[0-9a-f]{32}' build/src/chan_quectel.so | sort -u)
   grep -Fac "$SUM" "$(command -v asterisk)"
   ```
   The module must yield exactly one sum and the daemon must contain it (non-zero count). Do not
   list the daemon's 32-hex matches and eyeball the head of them — decimal-digit runs in the
   binary also match and sort first. See **Part E.5** step 12.
7. **Runtime load** (`install-chan-quectel.cmake` stages into `install/` via `DESTDIR` and
   dispatches to presets that do not exist — **B5**; use `cmake --install` directly, and see
   **Part E.5** step 13):
   ```sh
   sudo cmake --install build --component chan-quectel
   asterisk -rx 'module load chan_quectel.so'
   asterisk -rx 'quectel show devices'
   asterisk -rx 'core show taskprocessors like chan-quectel'
   asterisk -rx 'core show channeltype Quectel'
   ```
   A `Check AST_BUILDOPT_SUM`-class mismatch surfaces here as Asterisk refusing the module
   (`main/loader.c:1836`).
8. **Functional smoke test:** with a modem attached — device reaches `Free`, place and answer a
   call (verifies `channel_tech` and the audio path), send an SMS via `QUECTEL_SEND_SMS`, and
   confirm an inbound SMS reaches the `sms` extension (verifies `pdu.c` → `smsdb.c` →
   `channel_start_local_json()`).
9. **Packaging:** `cmake -P make-package.cmake` → `dpkg-deb -I package/*.deb` shows
   `Architecture: arm64` and no `asterisk16`; lintian passes.
10. **Formatting:** `cmake --build build --target asterisk-chan-quectel-code-formatting-check`
    must actually run (not be skipped with the "clang-format not found" warning).
