#!/usr/bin/env bash
# Compila Sunshine con i patch di questo repo e produce il .deb in dist/.
#
# Usa Docker. La compilazione è pesante: i limiti di memoria/CPU qui sotto evitano che
# l'OOM killer del server fermi altri container. Se compilare uccide cc1plus ("Killed signal
# terminated program cc1plus") abbassare JOBS o alzare MEM/SWAP.
#
#   build/build.sh                      # tutto
#   STOP_AFTER=prepare build/build.sh   # solo sorgenti + patch + web UI
#   STOP_AFTER=configure build/build.sh # fino alla configurazione di CMake
#
set -euo pipefail

UPSTREAM_URL="https://github.com/LizardByte/Sunshine.git"
UPSTREAM_COMMIT="949570130bceee7d0c4406f0daf94968ec6213aa"
UPSTREAM_VERSION="2026.1113.212932"
# Immagine ufficiale dello STESSO commit: serve solo per prenderne la web UI già compilata
WEBUI_IMAGE="lizardbyte/sunshine:v${UPSTREAM_VERSION}-ubuntu-24.04"
RELEASE_SUFFIX="${RELEASE_SUFFIX:-legacy.1}"

MEM="${MEM:-5g}"
SWAP="${SWAP:-9g}"      # valore di --memory-swap (RAM + swap)
CPUS="${CPUS:-4}"
JOBS="${JOBS:-1}"       # compilazioni in parallelo: ~1,5-3 GB di RAM ciascuna
STOP_AFTER="${STOP_AFTER:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$HERE/work}"
DIST="$HERE/dist"
SRC="$WORK/src"

step() { printf '\n== %s\n' "$*"; }

# I file creati dal container sono di root: si tolgono con Docker, non con rm.
if [[ "${1:-}" == "clean" ]]; then
  docker run --rm --user root -v "$WORK:/w" --entrypoint sh ubuntu:24.04 -c 'rm -rf /w/*'
  exit 0
fi

step "1/6 sorgenti upstream al commit fissato"
mkdir -p "$SRC" "$DIST"
if [[ ! -d "$SRC/.git" ]]; then
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$UPSTREAM_URL"
fi
git -C "$SRC" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SRC" checkout -q --force FETCH_HEAD

step "2/6 sottomoduli necessari"
# build-deps SENZA ricorsione: dentro ci sono i sorgenti di FFmpeg, x264 ecc. che non servono
# (il build scarica da solo i binari FFmpeg precompilati).
git -C "$SRC" submodule update --init --depth 1 third-party/build-deps
for p in glad libdisplaydevice libvirtualhid lizardbyte-common moonlight-common-c \
         plasma-wayland-protocols Simple-Web-Server tray wayland-protocols wlr-protocols; do
  git -C "$SRC" submodule update --init --recursive --force --depth 1 "third-party/$p"
done

step "3/6 patch"
# Si riparte dal commit pulito, così lo script si può rilanciare.
git -C "$SRC" checkout -q --force FETCH_HEAD -- src cmake scripts
for p in "$HERE"/patches/*.patch; do
  echo "applico $(basename "$p")"
  git -C "$SRC" apply "$p"
done

step "4/6 web UI precompilata"
# Vite/Rolldown usa istruzioni AVX2: su CPU senza AVX2 (es. AMD FX) termina con
# "Illegal instruction". La web UI è HTML/JS statico: si prende quella dell'immagine ufficiale.
rm -rf "$SRC/webui-prebuilt"
cid="$(docker create "$WEBUI_IMAGE")"
docker cp "$cid:/usr/share/sunshine/web" "$SRC/webui-prebuilt"
docker rm "$cid" >/dev/null

[[ "$STOP_AFTER" == "prepare" ]] && { echo "fermo dopo: prepare"; exit 0; }

step "5/6 immagine con le dipendenze di build"
ctx="$WORK/deps-ctx"
rm -rf "$ctx" && mkdir -p "$ctx/scripts" "$ctx/packaging/linux"
cp "$SRC/scripts/linux_build.sh" "$ctx/scripts/"
cp -r "$SRC/packaging/linux/patches" "$ctx/packaging/linux/"
docker build -q -t sunshine-legacy-deps -f "$HERE/build/Dockerfile.deps" "$ctx"

step "6/6 configurazione, compilazione e pacchetto (limiti: ${MEM} RAM, ${CPUS} CPU, ${JOBS} job)"
docker rm -f sunshine-legacy-build >/dev/null 2>&1 || true
docker run --rm --name sunshine-legacy-build \
  --memory="$MEM" --memory-swap="$SWAP" --cpus="$CPUS" \
  -v "$SRC:/build/sunshine" -w /build/sunshine \
  -e BRANCH=legacy -e COMMIT="${UPSTREAM_COMMIT:0:7}" -e BUILD_VERSION="$UPSTREAM_VERSION" \
  -e DEBIAN_PACKAGE_RELEASE=1+ubuntu24.04 \
  -e STOP_AFTER="$STOP_AFTER" -e JOBS="$JOBS" \
  sunshine-legacy-deps bash -c '
    set -e
    git config --global --add safe.directory "*"
    ./scripts/linux_build.sh --step=cmake --skip-cuda --sudo-off \
      --publisher-name="sunshine-legacy" --publisher-website="" --publisher-issue-url=""
    [[ "$STOP_AFTER" == "configure" ]] && exit 0
    ./scripts/linux_build.sh --step=build --skip-cuda --sudo-off --num-processors="$JOBS"
    ./scripts/linux_build.sh --step=package --skip-cuda --sudo-off
  '
[[ "$STOP_AFTER" == "configure" ]] && { echo "fermo dopo: configure"; exit 0; }

deb="$(ls "$SRC"/build/cpack_artifacts/*.deb | head -1)"
out="$DIST/sunshine-legacy_${UPSTREAM_VERSION}-${RELEASE_SUFFIX}_ubuntu24.04_amd64.deb"
cp "$deb" "$out"
( cd "$DIST" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
echo
echo "Pacchetto: $out"
cat "$out.sha256"
