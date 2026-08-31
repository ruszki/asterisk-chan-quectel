#!/bin/bash -e
#
# configure-asterisk-22.sh - produce a configured Asterisk 22 tree usable as AST_HEADER_DIR
#
# The pristine release tree is never touched: it is copied first, and the copy is
# configured.  Keeping the reference tree byte-identical to the upstream tarball is
# what makes `diff` against it trustworthy when checking API questions.
#
# Usage:  tools/configure-asterisk-22.sh [<src-tree>] [<dest-tree>]
#
#   <src-tree>   unpacked, unconfigured asterisk-22.x.y tarball
#                default: $ASTERISK_22_SRC
#   <dest-tree>  where the configured copy goes
#                default: $ASTERISK_22_BUILD, else <src-tree>-configured
#
# Environment:
#   AST_PROFILE=headers|daemon
#                              headers (default) - the leanest tree that can serve as
#                              AST_HEADER_DIR; daemon - additionally usable as a PBX,
#                              with XML documentation and the English core sounds and
#                              music-on-hold.  Both profiles leave MENUSELECT_CFLAGS at
#                              exactly OPTIONAL_API, so buildopts.h and AST_BUILDOPT_SUM
#                              are byte-identical between them.
#   AST_LIBDIR=<triplet>       Debian multiarch triplet used for --libdir, autodetected;
#                              set it to an empty string to keep autoconf's /usr/lib
#   FORCE=1                    reconfigure an existing <dest-tree> (it is removed first)
#   AST_DOWNLOAD_CACHE=<dir>   passed as --with-download-cache; required for an offline
#                              configure, since third-party/{pjproject,jansson,libjwt}
#                              are fetched at configure time
#   AST_CODEC_ARGS=<flags>     override the codec group below wholesale
#
# The codec group inherited from the old CI action uses --with-*, which makes those
# libraries MANDATORY - ./configure aborts at "checking for mandatory modules" if one is
# missing.  Each is demoted to --without-* automatically when pkg-config cannot see it,
# because none of them is needed by chan_quectel; install libopus-dev / libopusfile-dev /
# libogg-dev / libspeexdsp-dev first if you want them in the daemon.
#
# On success it prints the AST_HEADER_DIR value to use, e.g.
#   cmake -P make-build-dir.cmake default 220000   with
#   -DAST_HEADER_DIR=<dest-tree>/include
#
# To also build and install the daemon from the very same tree - which is what makes the
# module's and the daemon's AST_BUILDOPT_SUM agree by construction - use AST_PROFILE=daemon
# and continue with
#   cd <dest-tree> && make -j"$(nproc)" && sudo make install
#

echoerr() { echo "$@" 1>&2; }
die() { echoerr "$@"; exit 1; }

AST_SRC=${1:-${ASTERISK_22_SRC}}
[ -n "${AST_SRC}" ] || die "No source tree given: pass it as \$1 or set ASTERISK_22_SRC"
AST_SRC=$(cd "${AST_SRC}" 2>/dev/null && pwd) || die "Not a directory - ${1:-${ASTERISK_22_SRC}}"

AST_DST=${2:-${ASTERISK_22_BUILD:-${AST_SRC}-configured}}

# 1. Sanity-check the source tree.
[ -r "${AST_SRC}/.version" ] || die "No .version in ${AST_SRC} - not an Asterisk release tarball"
AST_VER=$(cat "${AST_SRC}/.version")
case "${AST_VER}" in
    22.*) ;;
    *) die "Expected an Asterisk 22 tree, found version ${AST_VER} in ${AST_SRC}" ;;
esac
[ -x "${AST_SRC}/configure" ] || die "No ./configure in ${AST_SRC}"

# 2. Copy.  Never configure the reference tree in place.
if [ -e "${AST_DST}" ]; then
    if [ "${FORCE}" = "1" ]; then
        echoerr "Removing existing ${AST_DST}"
        rm -rf "${AST_DST}"
    elif [ -r "${AST_DST}/include/asterisk/buildopts.h" ]; then
        echoerr "Already configured: ${AST_DST}  (set FORCE=1 to redo)"
        echo "${AST_DST}/include"
        exit 0
    else
        die "${AST_DST} exists but is not configured - set FORCE=1 to replace it"
    fi
fi
echoerr "Copying ${AST_SRC} -> ${AST_DST}"
cp -a "${AST_SRC}" "${AST_DST}"

cd "${AST_DST}"

DOWNLOAD_CACHE_ARG=()
if [ -n "${AST_DOWNLOAD_CACHE}" ]; then
    DOWNLOAD_CACHE_ARG=(--with-download-cache="${AST_DOWNLOAD_CACHE}")
fi

# Build profile.  Both profiles pass the same menuselect compiler flags, and
# build_tools/make_buildopts_h hashes nothing but MENUSELECT_CFLAGS, so buildopts.h -
# and with it AST_BUILDOPT_SUM - is byte-identical whichever profile is used.  Neither
# --disable-xmldoc, nor the sound packages, nor --libdir, nor the module selection, nor
# any other ./configure flag enters the checksum.
AST_PROFILE=${AST_PROFILE:-headers}
case "${AST_PROFILE}" in
    headers | daemon) ;;
    *) die "Unknown AST_PROFILE - ${AST_PROFILE} (expected 'headers' or 'daemon')" ;;
esac

# Asterisk puts its modules in ${libdir}/asterisk/modules and libdir defaults to
# /usr/lib, but chan_quectel.so installs to lib/${CMAKE_LIBRARY_ARCHITECTURE}/asterisk/
# modules - the Debian multiarch path (src/CMakeLists.txt).  Line the two up, or the
# daemon will never find the module.  Set AST_LIBDIR= (empty) to keep autoconf's default.
if [ -z "${AST_LIBDIR+x}" ]; then
    AST_LIBDIR=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null) ||
        AST_LIBDIR=$("${CC:-gcc}" -print-multiarch 2>/dev/null) ||
        AST_LIBDIR=
fi
LIBDIR_ARG=()
AST_MODDIR=/usr/lib/asterisk/modules
if [ -n "${AST_LIBDIR}" ]; then
    LIBDIR_ARG=(--libdir=/usr/lib/"${AST_LIBDIR}")
    AST_MODDIR=/usr/lib/${AST_LIBDIR}/asterisk/modules
fi

# XML documentation is dead weight when all we want is headers, but a daemon without it
# answers `core show application ...` with nothing.
XMLDOC_ARG=(--disable-xmldoc)
if [ "${AST_PROFILE}" = "daemon" ]; then
    XMLDOC_ARG=()
fi

# Mandatory-if-requested codec libraries: keep --with- only where pkg-config finds them.
if [ -n "${AST_CODEC_ARGS+x}" ]; then
    read -r -a CODEC_ARGS <<< "${AST_CODEC_ARGS}"
else
    CODEC_ARGS=()
    for lib in speexdsp ogg opus opusfile; do
        if pkg-config --exists "${lib}" 2>/dev/null; then
            CODEC_ARGS+=(--with-"${lib}")
        else
            echoerr "pkg-config cannot see ${lib} - configuring --without-${lib}"
            CODEC_ARGS+=(--without-"${lib}")
        fi
    done
fi

# 3. Configure.  The --without-* list is inherited from the retired CI action
#    (.github/actions/install-asterisk-headers/configure-asterisk.sh on master);
#    unknown --without-* flags are only autoconf warnings, so obsolete ones are harmless.
./configure \
    "${DOWNLOAD_CACHE_ARG[@]}" \
    "${CODEC_ARGS[@]}" \
    "${LIBDIR_ARG[@]}" \
    "${XMLDOC_ARG[@]}" \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --bindir=/usr/bin \
    --sbindir=/usr/bin \
    --disable-dev-mode \
    --disable-internal-poll \
    --without-oss \
    --without-portaudio \
    --without-jack \
    --without-x11 \
    --without-vpb \
    --without-gtk2 \
    --without-gmime \
    --without-sdl \
    --without-avcodec \
    --without-bluetooth \
    --without-iodbc \
    --without-imap \
    --without-inotify \
    --without-sqlite \
    --without-sndfile \
    --without-mysqlclient \
    --without-postgres \
    --without-iksemel \
    --without-openr2 \
    --without-radius \
    --without-resample \
    --without-spandsp \
    --without-tds \
    --without-neon29 \
    --without-neon \
    --without-pri \
    --without-ss7 \
    --without-dahdi \
    --without-misdn \
    --without-suppserv \
    --without-tonezone \
    --without-fftw3 \
    --without-unbound \
    --without-vorbis \
    --without-speex \
    --without-ilbc \
    1>&2

make menuselect.makeopts 1>&2

# 4. Module selection.
#    Nine members of the old CI list no longer exist in Asterisk 22 and were removed:
#      chan_sip chan_skinny chan_mgcp res_monitor cdr_syslog
#      app_ices app_image app_nbscat app_url
#    menuselect sets res=1 on an unknown member and then skips generate_makeopts_file()
#    entirely, so a single stale name silently leaves menuselect.makeopts unwritten.
#    LOW_MEMORY is also gone: it was a 32-bit RPi1 optimisation, it only shrinks
#    AST_NUM_CHANNEL_BUCKETS / AST_PBX_MAX_STACK on a 64-bit host, and it is excluded
#    from the checksum by build_tools/make_buildopts_h - so a divergence in it would not
#    even be caught by the Check AST_BUILDOPT_SUM test.
#    The sound packages and the file-format modules that read them travel together.
#    The headers profile wants none of them; the daemon profile wants the English core
#    sounds and music-on-hold, plus format_gsm, without which the .gsm variants it just
#    downloaded are unplayable (.wav is format_wav and .g722 is format_pcm, both kept).
#    EXTRA-SOUNDS-EN-* stays off in both profiles - a large download nothing here uses.
SOUND_ARGS=()
if [ "${AST_PROFILE}" = "daemon" ]; then
    SOUND_ARGS+=(--enable format_gsm)
else
    SOUND_ARGS+=(--disable format_gsm)
fi
for pkg in CORE-SOUNDS-EN MOH-OPSOUND; do
    for fmt in WAV GSM G722; do
        if [ "${AST_PROFILE}" = "daemon" ]; then
            SOUND_ARGS+=(--enable "${pkg}-${fmt}")
        else
            SOUND_ARGS+=(--disable "${pkg}-${fmt}")
        fi
    done
done
for fmt in WAV GSM G722; do
    SOUND_ARGS+=(--disable "EXTRA-SOUNDS-EN-${fmt}")
done

menuselect/menuselect \
    --disable BUILD_NATIVE \
    --disable codec_speex \
    --disable codec_ilbc \
    --disable codec_lpc10 \
    --disable codec_g726 \
    --disable codec_adpcm \
    --enable func_speex \
    --disable cdr_sqlite3_custom \
    --disable cel_sqlite3_custom \
    --disable format_wav_gsm \
    --disable format_siren7 \
    --disable format_siren14 \
    --disable format_ilbc \
    --disable format_g719 \
    --disable format_g723 \
    --disable format_g726 \
    --disable format_h263 \
    --disable format_h264 \
    --disable format_vox \
    --disable res_fax \
    --disable res_fax_spandsp \
    --disable res_format_attr_h263 \
    --disable res_format_attr_h264 \
    --disable res_config_pgsql \
    --disable res_format_attr_siren14 \
    --disable res_format_attr_siren7 \
    --disable res_format_attr_vp8 \
    --disable res_format_attr_ilbc \
    --disable res_speech \
    --disable res_config_ldap \
    --disable res_format_attr_silk \
    --enable res_snmp \
    --disable res_adsi \
    --disable app_festival \
    --disable app_mp3 \
    --disable app_sms \
    --disable app_test \
    --enable app_flash \
    --disable chan_unistim \
    --disable chan_iax2 \
    --disable chan_motif \
    --disable astdb2sqlite3 \
    --disable astdb2bdb \
    --disable astcanary \
    "${SOUND_ARGS[@]}" \
    menuselect.makeopts 1>&2

# 5. Generate the two headers the chan-quectel build needs.
#    autoconfig.h comes from ./configure (AC_CONFIG_HEADERS), buildopts.h from this target.
make include/asterisk/buildopts.h 1>&2

# 6. Verify.
for h in include/asterisk/autoconfig.h include/asterisk/buildopts.h; do
    [ -r "${h}" ] || die "Expected ${AST_DST}/${h} to exist after configuring"
done
echoerr "AST_BUILDOPT_SUM: $(sed -n 's/.*AST_BUILDOPT_SUM[[:space:]]*"\([0-9a-f]*\)".*/\1/p' include/asterisk/buildopts.h)"
echoerr "Asterisk ${AST_VER} configured in ${AST_DST}  (profile: ${AST_PROFILE})"
echoerr "Module directory: ${AST_MODDIR}"
echoerr "Use: -DAST_HEADER_DIR=${AST_DST}/include -DASTERISK_VERSION_NUM=220000"
if [ "${AST_PROFILE}" = "daemon" ]; then
    echoerr "Then: cd ${AST_DST} && make -j\"\$(nproc)\" && sudo make install && sudo make samples"
fi
echo "${AST_DST}/include"
