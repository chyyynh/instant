#!/bin/zsh
# End-to-end check of the live pipeline on real speech. Prints a report per sample and keeps traces in /tmp.
#   ./script/e2e.sh            # all samples
#   ./script/e2e.sh podcast    # one sample
set -euo pipefail
cd "$(dirname "$0")/.."
SAMPLES=Samples
PODCAST="$SAMPLES/yuru-pepper.mp3"

# Real conversational Japanese (ゆる言語学ラジオ, from the show's public podcast feed). Not committed.
if [[ ! -f "$PODCAST" ]]; then
  echo "Downloading podcast sample…"
  curl -sL -o "$PODCAST" "https://api.robotstart.jp/api/for-media/v1/articles/35d00481/permanent/with-advertise/podcast/df39b1b3ffc4b0b4e331246efacb6ed4.mp3"
fi

(cd Packages/InstantCore && swift build -q --product instant-lab)
LAB=Packages/InstantCore/.build/out/Products/Debug/instant-lab

run() { "$LAB" run "$@"; }
case "${1:-all}" in
  podcast|all) run "$PODCAST" --start 150 --duration 90 --trace /tmp/instant-e2e-podcast.jsonl ;|
  meeting|all) run "$SAMPLES/ja-meeting.aiff" --trace /tmp/instant-e2e-meeting.jsonl ;;
esac
