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
# module's and the daemon's AST_BUILDOPT_SUM agree by construction - continue with
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
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --bindir=/usr/bin \
    --sbindir=/usr/bin \
    --disable-xmldoc \
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
    --disable format_gsm \
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
    --disable CORE-SOUNDS-EN-WAV \
    --disable CORE-SOUNDS-EN-GSM \
    --disable CORE-SOUNDS-EN-G722 \
    --disable MOH-OPSOUND-WAV \
    --disable MOH-OPSOUND-GSM \
    --disable MOH-OPSOUND-G722 \
    --disable EXTRA-SOUNDS-EN-WAV \
    --disable EXTRA-SOUNDS-EN-GSM \
    --disable EXTRA-SOUNDS-EN-G722 \
    menuselect.makeopts 1>&2

# 5. Generate the two headers the chan-quectel build needs.
#    autoconfig.h comes from ./configure (AC_CONFIG_HEADERS), buildopts.h from this target.
make include/asterisk/buildopts.h 1>&2

# 6. Verify.
for h in include/asterisk/autoconfig.h include/asterisk/buildopts.h; do
    [ -r "${h}" ] || die "Expected ${AST_DST}/${h} to exist after configuring"
done
echoerr "AST_BUILDOPT_SUM: $(sed -n 's/.*AST_BUILDOPT_SUM[[:space:]]*"\([0-9a-f]*\)".*/\1/p' include/asterisk/buildopts.h)"
echoerr "Asterisk ${AST_VER} configured in ${AST_DST}"
echoerr "Use: -DAST_HEADER_DIR=${AST_DST}/include -DASTERISK_VERSION_NUM=220000"
echo "${AST_DST}/include"
