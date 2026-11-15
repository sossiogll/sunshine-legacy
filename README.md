# sunshine-legacy

*[Italiano](README.it.md)*

[Sunshine](https://github.com/LizardByte/Sunshine) (the Moonlight game-streaming host) **at its latest version**,
with support for **NVIDIA GPUs on old drivers**: Kepler (GeForce 600/700 series) and the legacy 470 driver.

This is not a fork with its own development: it is upstream at a pinned commit (see [`UPSTREAM`](UPSTREAM)) plus
a few small patches in [`patches/`](patches/) and a build recipe.

## Why it exists

On Linux, Sunshine encodes with NVENC through CUDA: its runtime is built with CUDA 12 and its kernels are
generated for architectures 50 (Maxwell) and up. On a GTX 660 (GK106, compute capability 3.0, driver 470 =
CUDA 11.4) the result is:

```
Error: Couldn't create cuda stream: cudaErrorInsufficientDriver:
       CUDA driver version is insufficient for CUDA runtime version
Info:  Encoder [nvenc] failed
```

Yet the card's hardware encoder works: `libavcodec` with the NVENC 11.1 headers encodes just fine (the official
Sunshine already loads `NVENC API 11.1, SDK 11.0 implementation`). Only Sunshine's CUDA path cannot run. This
repo adds an encoder that does not use it.

## What differs from upstream

| Patch | What it does |
|---|---|
| [`0001-nvenc_sw-encoder-senza-cuda.patch`](patches/0001-nvenc_sw-encoder-senza-cuda.patch) | Adds the **`nvenc_sw`** encoder: libavcodec's `h264_nvenc` fed with YUV420P frames in system memory, the way the `software` encoder works with libx264. H.264 only (first-generation NVENC has no HEVC or AV1). `multipass` pinned to `disabled`, the only mode Kepler accepts. **No** `surfaces = 1` (which the official CUDA encoder uses): with frames in RAM a single input buffer serializes upload and encoding |
| [`0002-build-senza-vulkan-e-senza-test.patch`](patches/0002-build-senza-vulkan-e-senza-test.patch) | In the CUDA-less build, turns off Vulkan Video (not needed on Kepler, and it needs a nested submodule) and the unit tests (compiling them exhausts memory) |
| [`0003-web-ui-precompilata.patch`](patches/0003-web-ui-precompilata.patch) | Uses the prebuilt web UI instead of running Vite, which dies with `Illegal instruction` on CPUs without AVX2 (e.g. AMD FX) |
| [`0004-swscale-flag-veloci-senza-ridimensionamento.patch`](patches/0004-swscale-flag-veloci-senza-ridimensionamento.patch) | Sunshine converts colour with `SWS_LANCZOS \| SWS_ACCURATE_RND`, which disables the fast SIMD paths (about +25% CPU, measured with ffmpeg at 1080p). Without scaling it now uses `SWS_BILINEAR`; with real scaling the original flags remain. Possible side effect: less refined colour edges |

The build is CUDA-less (`--skip-cuda`). What is lost: NvFBC capture and the "NVENC from GPU memory" path, which
use Sunshine's CUDA kernels and cannot run on these cards (NvFBC was not tried separately).

**Cost:** colour conversion stays on the CPU (swscale), so encoding uses more CPU than a CUDA Sunshine (not
compared). That is why two things matter: the thread count (`min_threads`, see *Usage*) and the `swscale` flags
(patch 0004). Measured values are in the next section.

## Status: what is verified and what is not

Tested on 2026-11-13 on: GTX 660 (GK106), driver 470.256.02, Debian 13 (kernel 6.12.107), Xorg with the NVIDIA
driver on an HDMI output at 1920x1080@60.

Verified:
- the build produces a `.deb` (Ubuntu 24.04) with no errors;
- with `encoder = nvenc_sw` Sunshine starts, detects the display and picks the hardware encoder:
  `Found H.264 encoder: h264_nvenc [nvenc_sw]`;
- `ffmpeg` with the same NVENC 11.1 headers captures the Xorg screen and encodes at 60 fps (1080p, 10 Mbit/s)
  into a valid file;
- **real LAN streaming with Moonlight 6.2.0**: pairing succeeded and `glxgears` (OpenGL on the GPU) was visible
  on the client (the gears turn). Mouse-motion packets show up in Sunshine's log.

**Measured** (2026-11-13/14, `glxgears` at 1920x1080, Moonlight 6.2.0 on a laptop on the LAN, 15 Mbit/s; stats
read by hand from Moonlight's overlay, single screenshots, not long averages):

| Configuration | fps | Host latency min/max/avg | Container CPU |
|---|---|---|---|
| `legacy.1`, default `min_threads` (2) | 49.1 | 22.9 / 46.0 / 34.3 ms | about 138% |
| `legacy.1`, `min_threads = 6` | 53-56 (reported) | not read | about 220% |
| `legacy.2`, `min_threads = 6`, *Desktop* app (1080p screen, 1080p stream) | **59.99** | 11.9 / 18.7 / 16.8 ms | about 135% (with other load on the server) |
| `legacy.2`, `min_threads = 6`, *Desktop 720p* app (1280x720 screen, 1080p stream scaled up) | **60.14** | 16.0 / 28.0 / 21.3 ms | not measured |

In every case network and client were irrelevant (2 ms network, 0% frames lost, 0.3-0.6 ms decode): the limit
was colour conversion on the server. Both `legacy.2` screenshots show a 1920x1080 stream: with *Desktop 720p*
the server screen was 1280x720, so Sunshine scaled to 1080p (with the original, slower `swscale` flags) and
still held 60 fps, with about 4.5 ms more host latency (21.3 vs 16.8 ms on average). The screenshot-to-app
mapping was confirmed by whoever ran the test. The server also had other load (`chromium`, `celery`, load
average ~8), so the values are if anything conservative. `nvidia-smi` on 470 does not expose GPU or encoder
utilisation (`N/A`).

Added later, from real use (RetroArch games streamed to an Xbox running Moonlight; the Moonlight client on an
Android TV box with 32-bit Android and 1 GB of RAM was also reported working by its user): audio with the setup
in *Audio*, virtual gamepads, apps that start containers, 720p and 1080p streams. These are use reports, not
measurements.

**Not verified:**
- stability over sessions of hours (game sessions of minutes were tried);
- audio latency and sync (audio was heard on the client, not measured). **Without the PulseAudio server of the
  *Audio* section, Sunshine starts but the stream is silent** (`Couldn't connect to pulseaudio ... The stream
  will not have audio`);
- that the mouse cursor really moves on the server;
- virtual gamepads beyond our use (an Xbox as client, with RetroArch); they need `/dev/uinput` and `/dev/uhid`
  in the container;
- a build **from scratch** with the right parallelism (`build/build.sh` produced the `legacy.2` package, but
  resuming from already-compiled objects: about 6 minutes; the from-scratch time is not measured);
- GPUs other than the GTX 660.

## Building

Needs Docker. It pins upstream to [`UPSTREAM`](UPSTREAM), applies the patches, takes the web UI from the
official image of the same commit and builds in a container with memory limits:

```bash
build/build.sh                       # everything, produces dist/*.deb and the checksum
STOP_AFTER=prepare   build/build.sh  # sources, patches and web UI only
STOP_AFTER=configure build/build.sh  # up to the CMake configuration
MEM=6g SWAP=9g JOBS=2 build/build.sh # parallelism and memory (values used for legacy.2)
build/build.sh clean                 # container files are root-owned: remove them through Docker
```

**Mind the parallelism.** The official `linux_build.sh --step=build` runs `ninja` **without `-j`**:
`--num-processors` only applies to doxygen. That is why `build.sh` calls `ninja -j$JOBS` directly. With the
official behaviour (about 10 compilations at once on 8 cores) `cc1plus` is killed for lack of memory (`Killed
signal terminated program cc1plus`) even with 5 and 9 GB limits: what matters is not a precise amount of RAM
but a cap on jobs. An earlier version of this README gave times and RAM for "`JOBS=1`" and "`JOBS=3`": they had
never been measured with that parallelism and were wrong.

Measured: resuming from already-compiled objects with `JOBS=2`, `MEM=6g` took about 6 minutes. The time of a
from-scratch build with the right parallelism is not measured.

## Usage

1. You need **Xorg with the NVIDIA driver** on the GPU. Not Xvfb: it would draw in software. With no physical
   monitor Xorg starts (`AllowEmptyInitialConfiguration`) but the driver **exposes no RandR outputs** (driver
   README), and Sunshine finds no display: you need a **virtual monitor**, i.e. `Option "ConnectedMonitor"
   "DFP-1"` and `Option "CustomEDID" "DFP-1:/etc/X11/edid.bin"` in the `Device` section (EDID copied from your
   own monitor with `cat /sys/class/drm/card0-HDMI-A-1/edid`; `DFP-1` is the name the driver gives the output,
   Xorg's log says so). Tried with the HDMI cable unplugged, hot and cold, streaming from a Moonlight app on an
   Xbox. After every Xorg restart the container must be restarted too. The pixel clock limit is 340 MHz (no 4K60).
2. Runtime image (put the `.deb` in a folder as `sunshine.deb`):
   ```bash
   docker build -t sunshine-legacy -f build/Dockerfile.run <folder>
   ```
3. `config/.config/sunshine/sunshine.conf` (in the folder mounted on `/config`):
   ```
   encoder = nvenc_sw
   output_name = 2
   csrf_allowed_origins = https://192.168.1.3:47990
   min_threads = 6
   system_tray = disabled
   ```
   - `min_threads`: Sunshine hands it to the colour converter (default 2). On a slow CPU like an FX-8320E with
     2 threads the server produced ~49 fps; with 6, ~53-56; then patches 0001 and 0004 brought it to 60. On
     the software path it also sets the encoder *slices* (6 instead of 2). With `legacy.2` I did not try lower
     values: they might be enough.
   - `system_tray = disabled`: the container has no system tray (the log says `Failed to create system tray`)
     and in one start out of about seven Sunshine died with a segmentation fault (code 139) right when
     creating the icon. With the option off it did not recur in one try: that does not confirm it was the
     cause.
   - `output_name`: the id of the display to capture. Without it Sunshine takes the first one (often an
     unconnected output, e.g. `DVI-I-0`) and falls back to the whole desktop. The ids are in the startup log:
     `Detected display: HDMI-0 (id: 2) ... connected: true`.
   - `csrf_allowed_origins`: the addresses the web UI is opened from, as a comma-separated list. Without it
     the page shows *CSRF Protection Error* and the log names the blocked origin.
4. Start. All the options are needed:
   - `--network host`: without it X11 capture cannot connect (`Cannot open display`);
   - `--ipc=host`: X11 capture uses shared memory with Xorg, which the container cannot see. Without it the
     stream starts but the picture is **black** and the log keeps repeating `Could not get image reply`;
   - `--device /dev/uinput --device /dev/uhid`: for virtual input devices (as root in the container).
   ```bash
   docker run -d --name sunshine-legacy --network host --ipc=host --runtime nvidia --user root \
     -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
     -e DISPLAY=:0 -e XAUTHORITY=/xauth -v /run/xorg-nvidia.auth:/xauth:ro \
     -v /tmp/.X11-unix:/tmp/.X11-unix -v "$PWD/config:/config" -e HOME=/config \
     --device /dev/uinput --device /dev/uhid sunshine-legacy
   ```
   This is the bare minimum: **no audio** (see *Audio*) and no apps that start other containers (see *Apps that
   start containers*).
5. Pairing. **First** open `https://<host>:47990` and create a user and password (whoever gets there first
   chooses it), **then** add the PC in Moonlight by IP and enter the PIN in the *PIN* section. Until you create
   the credentials Sunshine does not save its own ID (log: `sunshine_state.json doesn't exist`), so a restart
   before that changes it. If in Moonlight the PC shows as **offline** ("no active address") even though
   requests arrive (the debug log shows `/serverinfo` every 5 seconds), the suspect is an entry with the old
   ID: delete the PC and add it again. This is a hypothesis, not confirmed by Moonlight's logs.
6. I did not try automatic host discovery (it needs mDNS/avahi on the host): add the PC in Moonlight **by IP**.
   To see anything you need an app that draws on the display (pick *Desktop* in Moonlight's list); *Steam Big
   Picture* needs Steam, which is not there.
7. **Low-resolution apps.** Sunshine's sample *Low Res Desktop* app runs `xrandr --output HDMI-1 --mode
   1920x1080`: on our server it fails (the output is `HDMI-0` and the container had no `xrandr`), and when a
   prep command fails Sunshine cancels the launch. The image now includes `xrandr` (package
   `x11-xserver-utils`); in `apps.json` you set, with your output name and the modes `xrandr` lists for your
   display:
   ```json
   { "name": "Desktop 720p",
     "prep-cmd": [ { "do": "xrandr --output HDMI-0 --mode 1280x720 --rate 60",
                     "undo": "xrandr --output HDMI-0 --mode 1920x1080 --rate 60" } ] }
   ```
   **Always give `--rate`.** `xrandr --mode 1920x1080` without a rate picks the first mode with that name,
   which on this display is the 119.88 Hz one (listed before the 60.00): the server's screen stays at 120 Hz
   even after the session, and an emulator with vertical sync on (RetroArch) runs at double speed. The
   `legacy.2` measurements above were probably taken with the screen at 119.88 Hz (not checked during the
   sessions); the stream rate is decided by the client anyway, which asked for 60 fps.
   If Moonlight asks for a 1080p stream while the screen is 720p, Sunshine scales (with the original `swscale`
   flags, more CPU): tried, the stream stays 1080p and holds 60 fps with 21.3 ms average host latency. For a
   truly reduced load you must also ask Moonlight for a 720p stream: not tried.

In the log you should see:

```
Info: Trying encoder [nvenc_sw]
Debug: [h264_nvenc] Driver supports NVENC API 11.1; using SDK 11.0 implementation
Info: Found H.264 encoder: h264_nvenc [nvenc_sw]
```

The first attempt with multiple reference frames fails (`Multiple reference frames are not supported by the
device`): expected, Sunshine falls back to automatic selection by itself.

## Audio

Sunshine does not play sound by itself: it **looks for a PulseAudio server** and, when a stream starts, creates
virtual sinks in it (`sink-sunshine-stereo`, ...) whose *monitor* it captures. The container has none: without
one the log says `Couldn't connect to pulseaudio ... The stream will not have audio` and the stream is silent.
A setup that works on our server (tried with RetroArch, heard on the client, not measured):

1. A **separate PulseAudio container**, started before Sunshine, with its socket in a Docker volume:
   ```dockerfile
   FROM debian:trixie-slim
   RUN apt-get update && apt-get install -y --no-install-recommends pulseaudio pulseaudio-utils \
       && rm -rf /var/lib/apt/lists/* && useradd -m -u 1000 -s /usr/sbin/nologin pa \
       && mkdir -p /run/pulse && chmod 777 /run/pulse
   COPY sunshine.pa /etc/pulse/sunshine.pa
   USER pa
   ENTRYPOINT ["pulseaudio", "--daemonize=no", "--exit-idle-time=-1", "--disable-shm", "--log-target=stderr", "-n", "-F", "/etc/pulse/sunshine.pa"]
   ```
   ```
   # sunshine.pa
   load-module module-native-protocol-unix socket=/run/pulse/native auth-anonymous=1
   load-module module-null-sink sink_name=host-null sink_properties=device.description=host-null
   set-default-sink host-null
   ```
   ```bash
   docker run -d --name pulse-sunshine --network none -v pulse-socket:/run/pulse pulse-sunshine
   ```
   - **Not as root**: PulseAudio as root without `--system` does not let clients load modules, and Sunshine
     creates its sinks with `module-null-sink`. No shared memory (`--disable-shm`) because containers do not
     share it.
   - The `host-null` sink only provides a default before a stream exists.
2. Add `-v pulse-socket:/run/pulse -e PULSE_SERVER=unix:/run/pulse/native` to Sunshine. Give the same volume and
   variable to the containers that must play sound (RetroArch, in our case): games play into the sink Sunshine
   creates and the audio reaches the client.
3. Worth knowing: the server's **physical monitor gets no audio** (the sinks are virtual). Anyone watching the
   server instead of the client hears nothing.

## Apps that start containers

In our setup Sunshine does not launch games with `cmd`: it starts and stops Docker containers from the
`prep-cmd` entries of `apps.json`. For that, Sunshine's container mounts the host's `docker` and its socket:

```
-v /usr/bin/docker:/usr/bin/docker:ro -v /var/run/docker.sock:/var/run/docker.sock
```

**Careful:** with the Docker socket, a container running as root is root on the host. That is only acceptable on
a network you trust (our server is reachable only from the LAN and a private VPN); do not expose Sunshine's
interface to the Internet.

Example (an app that starts an already-created container and stops it at the end of the session):

```json
{ "name": "RetroArch",
  "prep-cmd": [
    { "do": "docker rm -f retroarch-game", "undo": "" },
    { "do": "docker start retroarch-menu",  "undo": "docker stop -t 3 retroarch-menu" } ] }
```

- **One command per line, no quotes:** Sunshine does not handle them (`sh -c '...; ...'` gave exit code 2).
- **A failing command cancels the app launch.** If it can fail harmlessly, make it tolerant (we did that with a
  save-sync script that always exits 0). That is also why the container to start must already exist
  (`docker create`): if it is deleted the app no longer starts.
- An empty `undo` is allowed.
- After every Xorg restart the containers that use the display must be recreated.

## Reserving CPU cores

With a heavy emulator running (PS2) and software encoding, the two processes compete for the CPU and the stream
stutters. On our 8-core FX we pinned cores with `--cpuset-cpus`: Sunshine on `4-7`, the emulator on `0,2` (two
cores from different FX modules, which share L2 cache in pairs). They are passed to `docker run` for Sunshine
and for the emulator container. This is a choice for this CPU: on another one it must be measured again.

## License

Sunshine is GPL-3.0 and this repo's patches follow the same license ([`LICENSE`](LICENSE)). The release `.deb`
contains the Sunshine binary built with these patches; the corresponding sources are upstream at the commit in
[`UPSTREAM`](UPSTREAM) plus `patches/`. The build downloads the prebuilt FFmpeg binaries from
[LizardByte/build-deps](https://github.com/LizardByte/build-deps).
