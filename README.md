# sunshine-legacy

[Sunshine](https://github.com/LizardByte/Sunshine) (host per Moonlight) **all'ultima versione**,
con il supporto per le **GPU NVIDIA con driver vecchi**: Kepler (GeForce serie 600/700) e il driver
legacy 470.

Questo non è un fork con sviluppo proprio: è l'upstream a un commit fissato (vedi [`UPSTREAM`](UPSTREAM))
con tre piccoli patch in [`patches/`](patches/) e una ricetta per compilarlo.

## Perché esiste

Su Linux, Sunshine codifica con NVENC passando da CUDA: il suo runtime è compilato con CUDA 12 e i suoi
kernel sono generati per architetture dalla 50 (Maxwell) in su. Su una GTX 660 (GK106, compute capability
3.0, driver 470 = CUDA 11.4) il risultato è:

```
Error: Couldn't create cuda stream: cudaErrorInsufficientDriver:
       CUDA driver version is insufficient for CUDA runtime version
Info:  Encoder [nvenc] failed
```

Eppure l'encoder hardware della scheda funziona: `libavcodec` con gli header NVENC 11.1 la codifica
senza problemi (il Sunshine ufficiale carica già `NVENC API 11.1, SDK 11.0 implementation`). È solo il
percorso CUDA di Sunshine che non può girare. Questo repo aggiunge un encoder che non lo usa.

## Cosa cambia rispetto all'upstream

| Patch | Cosa fa |
|---|---|
| [`0001-nvenc_sw-encoder-senza-cuda.patch`](patches/0001-nvenc_sw-encoder-senza-cuda.patch) | Aggiunge l'encoder **`nvenc_sw`**: `h264_nvenc` di libavcodec con frame YUV420P in memoria di sistema, come fa l'encoder `software` con libx264. Solo H.264 (la prima generazione di NVENC non fa HEVC né AV1). `multipass` fissato a `disabled`, l'unica modalità che Kepler accetta |
| [`0002-build-senza-vulkan-e-senza-test.patch`](patches/0002-build-senza-vulkan-e-senza-test.patch) | Nella build senza CUDA spegne Vulkan Video (non serve su Kepler e richiede un sottomodulo annidato) e i test unitari (compilarli esaurisce la memoria) |
| [`0003-web-ui-precompilata.patch`](patches/0003-web-ui-precompilata.patch) | Usa la web UI già compilata invece di lanciare Vite, che su CPU senza AVX2 (es. AMD FX) termina con `Illegal instruction` |

La build è senza CUDA (`--skip-cuda`). Cosa si perde: la cattura NvFBC e il percorso "NVENC da memoria
GPU", che usano i kernel CUDA di Sunshine, non eseguibili su queste schede (non ho provato NvFBC
separatamente).

**Costo:** la conversione colore resta sulla CPU (swscale), quindi la codifica usa più CPU di
un Sunshine con CUDA. Non è ancora misurato quanto.

## Stato: cosa è verificato e cosa no

Provato il 2026-11-13 su: GTX 660 (GK106), driver 470.256.02, Debian 13 (kernel 6.12.107), Xorg con il
driver NVIDIA su uscita HDMI a 1920x1080@60.

Verificato:
- la compilazione produce un `.deb` (Ubuntu 24.04) senza errori;
- con `encoder = nvenc_sw` Sunshine parte, rileva lo schermo e sceglie l'encoder hardware:
  `Found H.264 encoder: h264_nvenc [nvenc_sw]`;
- `ffmpeg` con gli stessi header NVENC 11.1 cattura lo schermo di Xorg e codifica a 60 fps
  (1080p, 10 Mbit/s) con file valido.

**Non verificato:**
- uno streaming reale con un client Moonlight (pairing, latenza, qualità);
- il carico di CPU della conversione colore;
- i gamepad virtuali (richiedono `/dev/uinput` e `/dev/uhid` nel container);
- che `build/build.sh` completo ripeta l'intera compilazione (ogni passo è stato eseguito a mano con gli
  stessi comandi; lo script è stato provato fino alla configurazione di CMake, vedi sotto);
- altre GPU oltre alla GTX 660.

## Compilare

Serve Docker. Fissa l'upstream a [`UPSTREAM`](UPSTREAM), applica i patch, prende la web UI dall'immagine
ufficiale dello stesso commit e compila in un container con limiti di memoria:

```bash
build/build.sh                       # tutto, produce dist/*.deb e il checksum
STOP_AFTER=prepare   build/build.sh  # solo sorgenti, patch e web UI
STOP_AFTER=configure build/build.sh  # fino alla configurazione di CMake
MEM=9g SWAP=11g JOBS=3 build/build.sh
build/build.sh clean                 # i file del container sono di root: si tolgono con Docker
```

Tempi indicativi su un AMD FX-8320E a 8 core con `JOBS=1`: da una a più ore. Con `JOBS=3` serve circa
9 GB di RAM libera; con meno, `cc1plus` viene ucciso (`Killed signal terminated program cc1plus`).

## Usare

1. Servono **Xorg con il driver NVIDIA** sulla GPU (anche senza schermo: `AllowEmptyInitialConfiguration`).
   Non Xvfb: disegnerebbe in software.
2. Immagine di esecuzione (il `.deb` va messo in una cartella come `sunshine.deb`):
   ```bash
   docker build -t sunshine-legacy -f build/Dockerfile.run <cartella>
   ```
3. `config/.config/sunshine/sunshine.conf` (nella cartella che si monta su `/config`):
   ```
   encoder = nvenc_sw
   ```
4. Avvio. `--network host` è necessario: senza, la cattura X11 non si collega (`Cannot open display`):
   ```bash
   docker run --rm --network host --runtime nvidia \
     -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
     -e DISPLAY=:0 -e XAUTHORITY=/xauth -v /run/xorg-nvidia.auth:/xauth:ro \
     -v /tmp/.X11-unix:/tmp/.X11-unix -v "$PWD/config:/config" -e HOME=/config \
     --user root sunshine-legacy
   ```
   Interfaccia di configurazione e pairing: `https://<host>:47990`.

Nel log si deve vedere:

```
Info: Trying encoder [nvenc_sw]
Debug: [h264_nvenc] Driver supports NVENC API 11.1; using SDK 11.0 implementation
Info: Found H.264 encoder: h264_nvenc [nvenc_sw]
```

Il primo tentativo con più reference frame fallisce (`Multiple reference frames are not supported by the
device`): è atteso, Sunshine ripiega da solo sulla selezione automatica.

## Licenza

Sunshine è GPL-3.0 e i patch di questo repo seguono la stessa licenza ([`LICENSE`](LICENSE)). Il `.deb`
delle release contiene il binario di Sunshine compilato con questi patch; i sorgenti corrispondenti sono
l'upstream al commit di [`UPSTREAM`](UPSTREAM) più `patches/`. La build scarica i binari FFmpeg
precompilati di [LizardByte/build-deps](https://github.com/LizardByte/build-deps).
