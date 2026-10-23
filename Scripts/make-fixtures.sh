#!/bin/zsh
# Generates the synthetic fixtures listed in Fixtures/README.md into Fixtures/synthetic.
# Real iPhone recordings live in Fixtures/real and are never generated.
#
# Usage: Scripts/make-fixtures.sh [--force]
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/Fixtures/synthetic"
FORCE="${1:-}"
mkdir -p "$OUT"

# testsrc draws a running timestamp, which makes timing visible in exported frames.
COLOR=(-color_primaries bt709 -color_trc bt709 -colorspace bt709)
X264=(-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p "${COLOR[@]}")
AAC=(-c:a aac -b:a 128k)

make() {
  local name="$1"; shift
  local dest="$OUT/$name"
  if [[ -f "$dest" && "$FORCE" != "--force" ]]; then
    echo "skip   $name"
    return
  fi
  echo "make   $name"
  ffmpeg -hide_banner -loglevel error -y "$@" -movflags +faststart "$dest"
}

tone() { echo "sine=frequency=${1}:sample_rate=48000:duration=${2}"; }

make landscape-sdr-30fps-6s.mov \
  -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=6" -f lavfi -i "$(tone 440 6)" \
  "${X264[@]}" "${AAC[@]}" -shortest

# 4K, for the 4K output resolution.
make uhd-landscape-30fps-4s.mov \
  -f lavfi -i "testsrc=size=3840x2160:rate=30:duration=4" -f lavfi -i "$(tone 440 4)" \
  "${X264[@]}" "${AAC[@]}" -shortest

# HDR: 10-bit HEVC tagged HLG, as iPhone records. The pattern is toned down to 30% saturation, like camera footage; its
# whites still lie above SDR white in HLG, so the HDR Key Photo needs its gain map.
make hdr-hlg-landscape-30fps-4s.mov \
  -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=4" -f lavfi -i "$(tone 440 4)" \
  -vf "hue=s=0.3,format=yuv420p,lutyuv=y=16+(val-16)*0.9" \
  -c:v libx265 -preset veryfast -crf 22 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
  "${AAC[@]}" -shortest

make silent-landscape-30fps-4s.mov \
  -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=4" \
  "${X264[@]}" -an

# Stored landscape with a display matrix that rotates it to portrait, like iPhone recordings.
# Encoding first and then remuxing keeps the pixels landscape; only the matrix changes.
ROTATED_SOURCE="$OUT/.rotated-source.mov"
if [[ ! -f "$OUT/rotated-portrait-sdr-30fps-5s.mov" || "$FORCE" == "--force" ]]; then
  make .rotated-source.mov \
    -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=5" -f lavfi -i "$(tone 523 5)" \
    "${X264[@]}" "${AAC[@]}" -shortest
fi
make rotated-portrait-sdr-30fps-5s.mov \
  -display_rotation:v:0 90 -i "$ROTATED_SOURCE" -c copy
rm -f "$ROTATED_SOURCE"

# Drops two of every seven frames while keeping their timestamps.
make vfr-30fps-5s.mov \
  -f lavfi -i "testsrc=size=1280x720:rate=30:duration=5" -f lavfi -i "$(tone 660 5)" \
  -vf "select='lt(mod(n\,7)\,5)'" -fps_mode vfr "${X264[@]}" "${AAC[@]}" -shortest

make hfr-120fps-4s.mov \
  -f lavfi -i "testsrc=size=1280x720:rate=120:duration=4" -f lavfi -i "$(tone 880 4)" \
  "${X264[@]}" "${AAC[@]}" -shortest

make short-2s.mov \
  -f lavfi -i "testsrc=size=1280x720:rate=30:duration=2" -f lavfi -i "$(tone 440 2)" \
  "${X264[@]}" "${AAC[@]}" -shortest

make short-0.8s.mov \
  -f lavfi -i "testsrc=size=1280x720:rate=30:duration=0.8" -f lavfi -i "$(tone 440 0.8)" \
  "${X264[@]}" "${AAC[@]}" -shortest

make too-short-0.3s.mov \
  -f lavfi -i "testsrc=size=1280x720:rate=30:duration=0.3" \
  "${X264[@]}" -an

# Frame-coded clips: 12 vertical bars spell the source frame index (round(t × rate)) in binary,
# least significant bit on the left, so tests can read exactly which source frame an output shows.
framecode() { echo "geq=lum='if(bitand(floor(T*${1}+0.5)\,pow(2\,floor(X*12/W)))\,235\,16)':cb=128:cr=128"; }

make framecode-30fps-6s.mov \
  -f lavfi -i "color=c=black:size=640x360:rate=30:duration=6,format=yuv420p,$(framecode 30)" \
  "${X264[@]}" -an

make framecode-120fps-4s.mov \
  -f lavfi -i "color=c=black:size=640x360:rate=120:duration=4,format=yuv420p,$(framecode 120)" \
  "${X264[@]}" -an

# The code is drawn before frames are dropped, so it keeps each surviving frame’s original index.
make framecode-vfr-6s.mov \
  -f lavfi -i "color=c=black:size=640x360:rate=30:duration=6,format=yuv420p,$(framecode 30),select='lt(mod(n\,7)\,5)'" \
  -fps_mode vfr "${X264[@]}" -an

# A white flash and a 1 kHz beep at the start of every second, for measuring A/V sync.
make av-sync-30fps-8s.mov \
  -f lavfi -i "color=c=black:size=640x360:rate=30:duration=8,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\,1)\,0.1)'" \
  -f lavfi -i "aevalsrc='if(lt(mod(t\,1)\,0.1)\,0.8*sin(2*PI*1000*t)\,0)':s=48000:d=8" \
  "${X264[@]}" "${AAC[@]}" -shortest

make long-10min.mov \
  -f lavfi -i "testsrc=size=640x360:rate=30:duration=600" -f lavfi -i "$(tone 330 600)" \
  -c:v libx264 -preset ultrafast -crf 32 -pix_fmt yuv420p "${COLOR[@]}" -c:a aac -b:a 64k -shortest

echo "done → $OUT"
