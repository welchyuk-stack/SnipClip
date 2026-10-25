#!/bin/zsh
# Records one App Preview clip: starts the recorder (Claude windows excluded),
# waits 1s, plays the clip's steps, then lets the recorder run out.
# Usage: ./take.sh 01_snip [seconds]
set -e
cd "${0:A:h}"
clip=$1; secs=${2:-20}
[[ -f clips/$clip.json ]] || { echo "No clips/$clip.json"; exit 1; }
[[ -x bin/rec && -x bin/drive ]] || ./build.sh
mkdir -p ../raw
./bin/rec "../raw/$clip.mov" $secs com.anthropic.claudefordesktop &
sleep 1
./bin/drive clips/$clip.json
wait
echo "Saved ../raw/$clip.mov"
ffmpeg -hide_banner -i "../raw/$clip.mov" -vf mpdecimate -f null - 2>&1 | grep -o "frame= *[0-9]*" | tail -1 | sed 's/frame=/unique frames:/'
