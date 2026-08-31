# Migrating asterisk-chan-quectel to Asterisk 22 on 64-bit Raspberry Pi OS

## Context

This fork exists to make `chan_quectel` work with Asterisk 22. The `asterisk-22` branch currently
contains **zero porting work** — `git diff --stat master asterisk-22` is only `.claude/CLAUDE.md`,
the CI deletion, and a `.gitignore` line.

The migration was investigated by diffing every Asterisk header the driver includes between
`/home/quectel/asterisk-20` (20.21.0) and `/home/quectel/asterisk-22` (22.11.0), auditing all 310
`ast_*`/`AST_*` identifiers used in `src/` against the 22 headers, and syntax-compiling the driver
against the 22.11.0 headers with `gcc -fsyntax-only -Wall`.

**Result: there is no C-level incompatibility.** Every blocker is in the build system, packaging,
or environment. Two environment facts drive the design:

1. **Debian 13 (trixie) ships no `asterisk` package at all.** Verified against
   `api.ftp-master.debian.org/madison`: asterisk exists in bullseye (16.28) and in
   testing/unstable = forky/sid (22.10.1), but **not in bookworm or trixie**;
   `packages.debian.org/trixie/asterisk` returns "Package not available". So on 64-bit Raspberry
   Pi OS, Asterisk 22 must be built from source — which is exactly what makes
   `/home/quectel/asterisk-22` the authoritative target.
2. **`/usr/include/asterisk` on this dev box is Debian-patched** (asterisk-dev 22.5.2). Its
   `taskprocessor.h:217` / `threadpool.h:189` declare `ast_taskprocessor_push` /
   `ast_threadpool_push` as **plain functions**, whereas pristine upstream (both 20 and 22)
   declares them as **macros expanding to `__ast_taskprocessor_push(..., __FILE__, __LINE__,
   __PRETTY_FUNCTION__)`**. Its `format_cache.h` also carries Debian-only `ast_format_amr`/`amrwb`.
   Building against `/usr/include` therefore produces a *different call graph* than building
   against the tree. This is a second, independent reason to stop using `/usr/include/asterisk`.

**Decisions taken:** build Asterisk 22.11.0 from the `asterisk-22` tree on the Pi; configure that
tree in place so it yields usable headers; full scope (build, packaging, docker, OpenWRT, docs);
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
| Version guards in `src/` | **Zero.** No `#if ASTERISK_VERSION_NUM` anywhere — keep it that way (commit `e93ef38` deleted the last shims). |
| Direct compile test | `src/{char_conv,error,eventfd,memmem,mixbuffer,ringbuffer,tty}.c` compile clean with `gcc -std=gnu99 -fsyntax-only -Wall -I/home/quectel/asterisk-22/include`. The rest stop only at the *generated* `ptime-config.h`, not at any Asterisk API. |

### A.2 Blockers — build system

| # | Blocker | Evidence | Effect |
| --- | --- | --- | --- |
| B1 | **No git tag.** `git tag -l` is empty. | `CMakeLists.txt:52-68` runs `git describe --match "v*" --long --tags` and `MESSAGE(FATAL_ERROR "Git - unable to describe")`. | Any `cmake --preset` aborts before anything else is evaluated. |
| B2 | **`AST_HEADER_DIR` at the tree hard-fails.** `/home/quectel/asterisk-22/include` has `asterisk.h` + `asterisk/` (so `ScanAsteriskHeadersDirectory` returns `DIRECTORY`), but has **no `asterisk/buildopts.h` and no `asterisk/autoconfig.h`**. | `CMakeLists.txt:214` `FIND_PATH(AST_HEADERS_SUBDIR NAMES buildopts.h … REQUIRED)`; `include/asterisk.h:21` `#include "asterisk/autoconfig.h"`. | Configure aborts with an opaque `FIND_PATH` error; even past that, every TU would fail on `autoconfig.h`. |
| B3 | **`ASTERISK_VERSION_NUM` silently defaults to `180000`.** No `asterisk.pc` exists here or on trixie. | `cmake/asterisk-version-num.cmake:36-39`; also defaulted to `180000` in `make-build-dir.cmake:13` and `configure-openwrt-makefile.cmake:6`. | A build against 22 headers is mislabelled as Asterisk 18 with no warning. Nothing derives it from the headers. |
| B4 | **`AST_BUILDOPT_SUM` is computed from whatever `buildopts.h` is found.** `ShowAstBuildOptSum()` (`cmake/asterisk-headers.cmake:57-80`) `TRY_RUN`s `test/asterisk/AST_BUILDOPT_SUM.c` against the resolved include dir; the ctest (`cmake/test/AST_BUILDOPT_SUM.cmake`) then greps that 32-hex string out of the built `.so`. | `src/CMakeLists.txt:110`. | This is only a *self*-consistency check. It cannot detect a mismatch with the Asterisk actually installed on the Pi — and a mismatch is what makes Asterisk refuse to load the module (`main/loader.c:1836`). Building Asterisk and the driver from the same configured tree makes them match by construction. |
| B5 | **`build-arm64` / `package-arm64` presets do not exist.** | `install-chan-quectel.cmake:5-11` and `make-package.cmake:5-11` dispatch to them; `CMakePresets.json` defines only `default` and `openwrt`; `get-build-flags.sh` generates only `deb`, `rpi`, `rpm`. | `./install-chan-quectel.cmake arm64` fails. |
| B6 | **`clang-format` is found only under the bare name.** `FindClangFormat` (`cmake/clang-format.cmake:31`) does `FIND_PROGRAM(… NAME clang-format)`. Trixie's `clang-format` alternative is **19**; `ClangFormatFindAndCheck(18)` (`CMakeLists.txt:97`) then rejects it and silently skips the formatting targets. | `clang-format-18` (1:18.1.8-18) *is* packaged in trixie, just under a versioned binary name. | Formatting silently goes unchecked on the Pi. |
| B7 | **Asterisk tree has no `.version`.** | `build_tools/make_version:11-14` → `UNKNOWN__and_probably_unsupported` when there is neither `.version` nor `.git`. | The Asterisk built on the Pi reports an unknown version in `core show version`, AMI, and CDRs. |

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

### Phase 1 — Turn `asterisk-22` into the authoritative header source

3. **Write `.version`** containing `22.11.0` into `/home/quectel/asterisk-22/`. Fixes **B7**.
4. **Add `tools/configure-asterisk-22.sh`** (new file). Base it on
   `git show master:.github/actions/install-asterisk-headers/configure-asterisk.sh`, with these
   changes (fixes **X3**):
   - **Delete** these menuselect arguments — the modules no longer exist in 22 and each makes
     `menuselect` exit non-zero: `--disable chan_sip`, `--disable chan_skinny`,
     `--disable chan_mgcp`, `--disable res_monitor`, `--disable cdr_syslog`,
     `--disable app_ices`, `--disable app_image`, `--disable app_nbscat`, `--enable app_url`.
   - **Drop `--enable LOW_MEMORY`.** It was a 32-bit RPi1 optimisation; on a 64-bit Pi it only
     shrinks `AST_NUM_CHANNEL_BUCKETS` (`channel.h:154`) and `AST_PBX_MAX_STACK` (`pbx.h:1665`).
     It is deliberately excluded from the checksum by `build_tools/make_buildopts_h`, so it would
     *not* be caught by the `AST_BUILDOPT_SUM` test if it ever diverged.
   - Keep the `--without-*` list as-is; obsolete ones are harmless autoconf warnings.
   - End with `make menuselect.makeopts`, the `menuselect/menuselect …` call, and
     `make include/asterisk/buildopts.h`.
   - Verify afterwards that **both** `include/asterisk/autoconfig.h` and
     `include/asterisk/buildopts.h` now exist. Fixes **B2**.
5. **Build and install Asterisk 22.11.0 on the Pi from that same tree**
   (`make -j$(nproc) && sudo make install && sudo make samples && sudo make config`).
   Because the module and the daemon come from one configured tree, their `AST_BUILDOPT_SUM`
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
7. **`CMakeLists.txt:213-217` — give the `buildopts.h` probe a real diagnostic.** Wrap the
   `FIND_PATH` so that on failure it names `tools/configure-asterisk-22.sh` instead of emitting a
   bare CMake `REQUIRED` error. Keep the probe itself; do not weaken it.
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
20. **Update `.claude/CLAUDE.md`** §1 (blessed sequence, header discovery, `180000` default now
    gone), §3 (record that 22.11.0 is the target and that `/usr/include` is Debian-patched),
    §4 if conventions shift.
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

After — and a full configure now runs to completion instead of aborting at `CMakeLists.txt:68`:

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

Three lines in that log are worth recording; **none of them is fixed by Phase 0**:

- `Asterisk header directory: /usr/include/` — the dev box silently fell back to the
  **Debian-patched** headers, precisely the hazard described in Context §2. The reported
  `AST_BUILDOPT_SUM` `1fb7f5c06d7a2052e38d021b3d8ca151` therefore belongs to Debian's
  asterisk-dev 22.5.2, **not** to 22.11.0, and is meaningless for the Pi. **B2** is what makes
  the source tree usable instead.
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

Do **not** run `./configure` or `make` in `~/src/asterisk-22` yet. That is Phase 1 (steps 3–5),
and it first needs `.version` written into the tree (**B7**) and the not-yet-written
`tools/configure-asterisk-22.sh`, whose menuselect list must drop the modules that no longer
exist in 22 (**X3**). Configuring the tree by hand now would produce a `buildopts.h` that Phase 1
would have to redo.

### C.3 — Status after Phase 0

| Blocker | State | Closed by |
| --- | --- | --- |
| **B1** no git tag | **Fixed** — `v2026.08.30` created and pushed | Phase 0 |
| B2 `buildopts.h` / `autoconfig.h` missing from the tree | open | Phase 1, steps 4–5 |
| B3 `ASTERISK_VERSION_NUM` defaults to `180000` | open | Phase 2, step 6 |
| B4 `AST_BUILDOPT_SUM` self-consistency only | open | Phase 1, step 5 (by construction) |
| B5 missing `build-arm64` / `package-arm64` presets | open | Phase 3, step 12 |
| B6 `clang-format` found only under the bare name | open (workaround: `-DCLANG_FORMAT=/usr/bin/clang-format-18`) | Phase 2, step 9 |
| B7 Asterisk tree has no `.version` | open | Phase 1, step 3 |
| P1–P4 packaging | open | Phase 3 |
| P5, P6 | verified as already correct — do not "fix" | — |
| X1, X2 docker | open | Phase 4 |
| X3 menuselect list invalid for 22 | open | Phase 1, step 4 |
| X4 OpenWRT | open | Phase 5 |
| X5 README | open | Phase 6 |
| X6 GCC 14 promoted warnings | unverified — needs a real build on the Pi | Verification, step 4 |

One housekeeping consequence: `get-source-date-epoch.sh` aborts on a dirty tree unless `PRESET`
is set, so **commit this chapter before attempting the blessed reproducible-build sequence**.

---

## Verification

Run in order; each step gates the next.

1. **Headers exist:** `ls /home/quectel/asterisk-22/include/asterisk/{autoconfig.h,buildopts.h}`
   and `grep AST_BUILDOPT_SUM /home/quectel/asterisk-22/include/asterisk/buildopts.h`.
2. **Configure:**
   ```sh
   cmake -P make-build-dir.cmake default 220000   # or the new rpi64 preset
   ```
   Assert the log shows `Asterisk version: 220000 [header]` (not `[default]`), and
   `Getting AST_BUILDOPT_SUM - <32 hex>` — not `unknown`.
3. **Full reproducible build + tests:**
   ```sh
   ./get-source-date-epoch.sh > .env
   ./get-build-flags.sh rpi64 > CMakeUserPresets.json
   ./dotenv.sh .env cmake -P make-build-dir.cmake rpi64 220000
   ./dotenv.sh .env cmake -P build-chan-quectel.cmake rpi64
   ctest --preset rpi64
   ```
   All five tests must pass, in particular **`Check AST_BUILDOPT_SUM`** and
   **`Check library dependencies`** (confirms only `libasound`, `libsqlite3`, `libc`,
   `libgcc_s`, `ld-linux-aarch64.so.1` are `NEEDED`).
4. **Compiler check (X6):** the build must be warning-free under GCC 14 with `-Wall`. Treat any
   `-Wincompatible-pointer-types` / `-Wint-conversion` as a hard failure — they are errors by
   default in GCC 14.
5. **ELF sanity:** `readelf -hW build/src/chan_quectel.so` reports `Machine: AArch64`,
   `Type: DYN`.
6. **Checksum agreement with the running daemon** — the check the ctest cannot do:
   ```sh
   grep -Eao '[0-9a-f]{32}' build/src/chan_quectel.so
   asterisk -rx 'core show settings' | grep -i 'build options'
   ```
   Confirm the module's embedded sum corresponds to the daemon's build options.
7. **Runtime load:**
   ```sh
   sudo cmake -P install-chan-quectel.cmake
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
