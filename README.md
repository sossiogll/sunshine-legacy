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
| [`0001-nvenc_sw-encoder-senza-cuda.patch`](patches/0001-nvenc_sw-encoder-senza-cuda.patch) | Aggiunge l'encoder **`nvenc_sw`**: `h264_nvenc` di libavcodec con frame YUV420P in memoria di sistema, come fa l'encoder `software` con libx264. Solo H.264 (la prima generazione di NVENC non fa HEVC né AV1). `multipass` fissato a `disabled`, l'unica modalità che Kepler accetta. **Senza** `surfaces = 1` (che l'encoder CUDA ufficiale usa): con frame in RAM un solo buffer d'ingresso fa serializzare caricamento e codifica |
| [`0002-build-senza-vulkan-e-senza-test.patch`](patches/0002-build-senza-vulkan-e-senza-test.patch) | Nella build senza CUDA spegne Vulkan Video (non serve su Kepler e richiede un sottomodulo annidato) e i test unitari (compilarli esaurisce la memoria) |
| [`0003-web-ui-precompilata.patch`](patches/0003-web-ui-precompilata.patch) | Usa la web UI già compilata invece di lanciare Vite, che su CPU senza AVX2 (es. AMD FX) termina con `Illegal instruction` |
| [`0004-swscale-flag-veloci-senza-ridimensionamento.patch`](patches/0004-swscale-flag-veloci-senza-ridimensionamento.patch) | Sunshine converte il colore con `SWS_LANCZOS \| SWS_ACCURATE_RND`, che disattiva i percorsi SIMD veloci (circa +25% di CPU, misurato con ffmpeg a 1080p). Senza ridimensionamento ora usa `SWS_BILINEAR`; con un ridimensionamento reale restano i flag originali. Effetto collaterale possibile: resa dei bordi di colore meno raffinata |

La build è senza CUDA (`--skip-cuda`). Cosa si perde: la cattura NvFBC e il percorso "NVENC da memoria
GPU", che usano i kernel CUDA di Sunshine, non eseguibili su queste schede (non ho provato NvFBC
separatamente).

**Costo:** la conversione colore resta sulla CPU (swscale), quindi la codifica usa più CPU di un Sunshine
con CUDA (non confrontato). Per questo contano due cose: il numero di thread (`min_threads`, vedi *Usare*) e i
flag di `swscale` (patch 0004). I valori misurati sono nella sezione seguente.

## Stato: cosa è verificato e cosa no

Provato il 2026-11-13 su: GTX 660 (GK106), driver 470.256.02, Debian 13 (kernel 6.12.107), Xorg con il
driver NVIDIA su uscita HDMI a 1920x1080@60.

Verificato:
- la compilazione produce un `.deb` (Ubuntu 24.04) senza errori;
- con `encoder = nvenc_sw` Sunshine parte, rileva lo schermo e sceglie l'encoder hardware:
  `Found H.264 encoder: h264_nvenc [nvenc_sw]`;
- `ffmpeg` con gli stessi header NVENC 11.1 cattura lo schermo di Xorg e codifica a 60 fps
  (1080p, 10 Mbit/s) con file valido;
- **streaming reale in LAN con Moonlight 6.2.0**: pairing riuscito e `glxgears` (OpenGL sulla GPU) visibile
  sul client (le rotelle girano). Nel log di Sunshine arrivano i pacchetti di movimento del mouse.

**Misurato** (2026-11-13/14, `glxgears` a 1920x1080, Moonlight 6.2.0 su un portatile in LAN, 15 Mbit/s;
statistiche lette a mano dalla sovraimpressione di Moonlight, singole schermate, non medie lunghe):

| Configurazione | fps | Latenza host min/max/media | CPU del container |
|---|---|---|---|
| `legacy.1`, `min_threads` predefinito (2) | 49,1 | 22,9 / 46,0 / 34,3 ms | circa 138% |
| `legacy.1`, `min_threads = 6` | 53-56 (riferiti) | non letta | circa 220% |
| `legacy.2`, `min_threads = 6`, app *Desktop* (schermo 1080p, flusso 1080p) | **59,99** | 11,9 / 18,7 / 16,8 ms | circa 135% (con altro carico sul server) |
| `legacy.2`, `min_threads = 6`, app *Desktop 720p* (schermo 1280x720, flusso 1080p ridimensionato) | **60,14** | 16,0 / 28,0 / 21,3 ms | non misurata |

In tutti i casi rete e client erano irrilevanti (2 ms di rete, 0% di frame persi, decodifica 0,3-0,6 ms): il
limite era la conversione colore sul server. Le due schermate di `legacy.2` mostrano entrambe un flusso
1920x1080: con *Desktop 720p* lo schermo del server era a 1280x720, quindi Sunshine ha ridimensionato a 1080p
(con i flag originali di `swscale`, più lenti) e i 60 fps sono comunque tenuti, con circa 4,5 ms di latenza
host in più (21,3 contro 16,8 ms in media). L'associazione schermata/app me l'ha confermata chi ha fatto la
prova. Sul server girava anche altro carico (`chromium`, `celery`, load average ~8), quindi i valori sono
semmai prudenti. `nvidia-smi` sul 470 non espone l'utilizzo di GPU né dell'encoder (`N/A`).

**Non verificato:**
- stabilità su sessioni lunghe e qualità percepita con contenuti reali (provato solo con `glxgears`);
- che il cursore del mouse si muova davvero sul server;
- i gamepad virtuali (richiedono `/dev/uinput` e `/dev/uhid` nel container);
- **l'audio: non funziona.** Nel container non c'è un server PulseAudio
  (`Couldn't connect to pulseaudio: Access denied ... The stream will not have audio`);
- un client sul box Android TV a 32 bit;
- una compilazione **da zero** con il parallelismo corretto (`build/build.sh` ha prodotto il pacchetto
  `legacy.2`, ma ripartendo da oggetti già compilati: circa 6 minuti; il tempo da zero non è misurato);
- altre GPU oltre alla GTX 660.

## Compilare

Serve Docker. Fissa l'upstream a [`UPSTREAM`](UPSTREAM), applica i patch, prende la web UI dall'immagine
ufficiale dello stesso commit e compila in un container con limiti di memoria:

```bash
build/build.sh                       # tutto, produce dist/*.deb e il checksum
STOP_AFTER=prepare   build/build.sh  # solo sorgenti, patch e web UI
STOP_AFTER=configure build/build.sh  # fino alla configurazione di CMake
MEM=6g SWAP=9g JOBS=2 build/build.sh # parallelismo e memoria (valori usati per legacy.2)
build/build.sh clean                 # i file del container sono di root: si tolgono con Docker
```

**Attenzione al parallelismo.** Lo script ufficiale `linux_build.sh --step=build` lancia `ninja` **senza
`-j`**: l'opzione `--num-processors` vale solo per doxygen. Per questo `build.sh` chiama `ninja -j$JOBS`
direttamente. Con il comportamento ufficiale (circa 10 compilazioni insieme su 8 core) `cc1plus` viene ucciso
per memoria (`Killed signal terminated program cc1plus`) anche con limiti di 5 e 9 GB: non servono quantità
precise di RAM, ma un limite ai job. Una versione precedente di questo README indicava tempi e RAM per
"`JOBS=1`" e "`JOBS=3`": non erano mai stati misurati con quel parallelismo, ed erano sbagliati.

Misurato: una ripresa da oggetti già compilati con `JOBS=2`, `MEM=6g` ha richiesto circa 6 minuti. Il tempo
di una compilazione da zero con il parallelismo corretto non è misurato.

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
   output_name = 2
   csrf_allowed_origins = https://192.168.1.3:47990
   min_threads = 6
   ```
   - `min_threads`: Sunshine lo passa al convertitore colore (default 2). Su una CPU lenta come un
     FX-8320E con 2 thread il server produceva ~49 fps; con 6, ~53-56; poi i patch 0001 e 0004
     hanno portato a 60. Nel percorso software determina anche le *slice* dell'encoder (6 invece di 2).
     Con `legacy.2` non ho provato valori più bassi: potrebbero bastare. l'id dello schermo da catturare. Senza, Sunshine prende il primo (spesso un'uscita non
     collegata, es. `DVI-I-0`) e ripiega sull'intero desktop. Gli id sono nel log all'avvio:
     `Detected display: HDMI-0 (id: 2) ... connected: true`.
   - `csrf_allowed_origins`: gli indirizzi da cui si apre l'interfaccia web, come lista separata da
     virgole. Senza, la pagina dà *CSRF Protection Error* e nel log compare l'origine bloccata.
4. Avvio. Tutte le opzioni servono:
   - `--network host`: senza, la cattura X11 non si collega (`Cannot open display`);
   - `--ipc=host`: la cattura X11 usa la memoria condivisa con Xorg, che il container non vede. Senza,
     lo stream parte ma l'immagine è **nera** e nel log si ripete `Could not get image reply`;
   - `--device /dev/uinput --device /dev/uhid`: per i dispositivi di input virtuali (da root nel container).
   ```bash
   docker run -d --name sunshine-legacy --network host --ipc=host --runtime nvidia --user root \
     -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all \
     -e DISPLAY=:0 -e XAUTHORITY=/xauth -v /run/xorg-nvidia.auth:/xauth:ro \
     -v /tmp/.X11-unix:/tmp/.X11-unix -v "$PWD/config:/config" -e HOME=/config \
     --device /dev/uinput --device /dev/uhid sunshine-legacy
   ```
5. Pairing. **Prima** apri `https://<host>:47990` e crea utente e password (chi arriva per primo la
   sceglie), **poi** aggiungi il PC in Moonlight con l'IP e inserisci il PIN nella sezione *PIN*.
   Finché non crea le credenziali Sunshine non salva il proprio ID (nel log: `sunshine_state.json
   doesn't exist`), quindi un riavvio prima di quel momento lo cambia. Se in Moonlight il PC risulta
   **offline** ("nessun indirizzo attivo") pur arrivando le richieste (nel log debug si vedono
   `/serverinfo` ogni 5 secondi), il sospetto è una voce con il vecchio ID: eliminare il PC e
   riaggiungerlo. È un'ipotesi, non confermata dai log di Moonlight.
6. Il rilevamento automatico dell'host non l'ho provato: aggiungi il PC in Moonlight **per IP**. Per
   vedere qualcosa serve un'app che disegni sul display (nell'elenco di Moonlight scegli *Desktop*);
   *Steam Big Picture* richiede Steam, che non c'è.
7. **App a bassa risoluzione.** L'app *Low Res Desktop* di esempio di Sunshine esegue
   `xrandr --output HDMI-1 --mode 1920x1080`: sul nostro server fallisce (l'uscita è `HDMI-0` e nel
   container non c'era `xrandr`), e quando un comando di preparazione fallisce Sunshine annulla l'avvio.
   L'immagine ora include `xrandr` (pacchetto `x11-xserver-utils`); in `apps.json` si imposta, con il nome
   dell'uscita e le modalità che `xrandr` elenca per il proprio schermo:
   ```json
   { "name": "Desktop 720p",
     "prep-cmd": [ { "do": "xrandr --output HDMI-0 --mode 1280x720 --rate 60",
                     "undo": "xrandr --output HDMI-0 --mode 1920x1080 --rate 60" } ] }
   ```
   **Indica sempre `--rate`.** `xrandr --mode 1920x1080` senza frequenza sceglie il primo modo con quel
   nome, che su questo schermo è quello a 119,88 Hz (elencato prima del 60,00): lo schermo del server
   resta a 120 Hz anche dopo la sessione, e un emulatore con la sincronia verticale attiva (RetroArch) va al
   doppio della velocità. Le misure di `legacy.2` riportate più sopra sono state prese probabilmente con lo
   schermo a 119,88 Hz (non controllato durante le sessioni); la frequenza dello stream la decide comunque
   il client, che chiedeva 60 fps.
   Se Moonlight chiede un flusso a 1080p mentre lo schermo è a 720p, Sunshine ridimensiona (con i flag
   originali di `swscale`, più CPU): provato, il flusso resta a 1080p e tiene 60 fps con 21,3 ms di
   latenza host in media. Per un vero carico ridotto va chiesto a Moonlight anche un flusso a 720p: non
   provato.

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
