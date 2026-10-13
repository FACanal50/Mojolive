# MojoLive — Módulo 1

App iOS nativa (Swift) de contribución de video para periodismo móvil.
**Módulo 1:** cámara con controles manuales, UI de producción, zócalos quemados en la señal y transmisión SRT directa.

## Requisitos

| | |
|---|---|
| Xcode | 15 o superior (probado con el SDK de iOS 17/18) |
| iOS mínimo | 16.0 · iPhone XS o posterior (A12+) recomendado; 4K60 requiere A13+ |
| Herramientas | `brew install xcodegen cmake` |
| Dependencias | **libsrt 1.5.4** (Haivision, MPL-2.0) + **mbedTLS 3.6** (Apache-2.0), compiladas como XCFramework estático. Sin CocoaPods ni SPM de terceros. |

## Puesta en marcha

```bash
cd MojoLive
./Scripts/build-libsrt.sh      # ~5 min: genera Vendor/libsrt.xcframework (device + simulador)
xcodegen generate              # genera MojoLive.xcodeproj desde project.yml
open MojoLive.xcodeproj        # completar DEVELOPMENT_TEAM y correr en un iPhone real
```

> La cámara, VideoToolbox y el micrófono **no funcionan en el simulador**: usá un equipo físico.

## Compilar en la nube (sin Mac) — GitHub Actions

El workflow `.github/workflows/build-ios.yml` compila todo en un runner macOS de GitHub en cada push a `main`:
instala xcodegen, compila libsrt (con caché), genera el proyecto, compila la app sin firmar, corre los tests y
publica **`MojoLive-unsigned.ipa`** como artifact descargable.

| Ejecución | Duración aprox. |
|---|---|
| Primera (compila libsrt) | 15–20 min |
| Siguientes (libsrt en caché) | 6–10 min |

**Costos:** en repositorios **públicos** Actions es gratis. En **privados** los minutos de macOS consumen la cuota
gratuita mucho más rápido que los de Linux (≈10×); revisá el consumo en *Settings → Billing*.

### Instalar la .ipa en el iPhone desde Windows (Sideloadly)

1. Instalá **iTunes** e **iCloud** versión web de Apple (no la de Microsoft Store) y luego **Sideloadly** (sideloadly.io).
2. Conectá el iPhone por cable y confiá en la PC.
3. En Sideloadly: arrastrá la `.ipa`, poné tu Apple ID y tocá **Start**. Sideloadly firma la app con tu cuenta.
4. En el iPhone: *Ajustes → Privacidad y seguridad → Modo de desarrollador* → activar (reinicia).
5. *Ajustes → General → VPN y gestión de dispositivos* → confiar en tu Apple ID.

Con un Apple ID **gratuito** la app vence a los **7 días** (se reinstala con Sideloadly) y hay un máximo de 3 apps.
Con la cuenta de **Apple Developer** (USD 99/año) se puede agregar firma + subida automática a **TestFlight** en el mismo workflow.

## Arquitectura

```
MojoLive/
├── App/                      Entrada SwiftUI + bloqueo de orientación
├── Core/                     ── sin dependencias de UI ──
│   ├── Models/               VideoProfile, SRTConfiguration, LowerThird (GraphicsState)
│   ├── Camera/               CameraController: formato, ISO, shutter, foco, WB (K), lentes
│   ├── Audio/                AudioCaptureEngine (entradas USB/BT/incorporado) + AudioLevelMeter
│   ├── Graphics/             OverlayRenderer (rasteriza 1 vez) + FrameCompositor (Core Image/Metal)
│   ├── Encoding/             VideoEncoder (H.264/HEVC HW) + AACEncoder (AAC-LC 48 kHz, ADTS)
│   ├── Streaming/            TSMuxer (MPEG-TS) · SRTTransport (libsrt) · AdaptiveBitrateController
│   ├── Pipeline/             BroadcastPipeline: orquesta todo
│   └── Utilities/            Persistencia (UserDefaults + Llavero), reloj, IPs locales
├── UI/                       ProductionView, paneles (cámara, gráfica, audio, SRT), vúmetro
└── Support/                  Bridging header → <srt/srt.h>
MojoLiveTests/                CRC MPEG-2, ADTS, paquetización TS, ABR
Scripts/build-libsrt.sh       Compila libsrt + mbedTLS → XCFramework
```

### Flujo de señal

```
Cámara 420v ─► FrameCompositor (GPU) ─┬─► Monitor de PROGRAMA (lo que sale al aire)
                 ▲ logo + zócalo      └─► VideoEncoder H.264/HEVC ─┐
                                                                  ├─► TSMuxer ─► SRTTransport ─► receptor
Micrófono ─► AudioCaptureEngine ─┬─► Vúmetro (pico/RMS)            │       (1316 B = 7×188)
                                 └─► AACEncoder ──────────────────┘
                          AdaptiveBitrateController ◄── estadísticas SRT (1 s)
```

**Decisiones clave**

- **Gráfica quemada sin costo por frame en CPU:** el zócalo y el logo se rasterizan solo cuando cambian y se componen en GPU sobre buffers IOSurface (sin copias). Si no hay gráfica en pantalla, el frame pasa directo (pass-through).
- **El monitor muestra la señal de programa**, no la preview cruda: lo que ve el periodista es exactamente lo que recibe la emisora.
- **Baja latencia de punta a punta:** el encoder trabaja en tiempo real y sin B-frames, el GOP es de 1 s y los PES salen sin buffering. El PCR se toma del reloj de host. Audio y video comparten la misma base de tiempo.
- **Audio limpio:** el modo `.measurement` desactiva el AGC y la supresión de ruido. El AAC sale siempre en estéreo 48 kHz (las fuentes mono se duplican en ambos canales) y se corrige el priming de 2112 muestras del encoder.
- **SRT:** funciona en modo Caller o Listener, con cifrado AES-128/192/256 y latencia de 120 a 2000 ms. Hay Stream ID, reconexión con backoff y mensajes de error legibles (por ejemplo, "Passphrase incorrecta").
- **Bitrate adaptativo (AIMD):** baja de forma fuerte ante descartes o un buffer SRT lleno, y moderada si el buffer crece, si hay pérdidas mayores al 5 % o si el RTT se infla. Sube un +8 % tras 3 s estables. Nunca supera el 75 % de la capacidad que estima SRT.

## Probar la recepción

En una PC de la redacción, en la misma red o con el puerto UDP abierto o redirigido:

```bash
# Móvil en modo CALLER → la PC escucha
ffplay -fflags nobuffer "srt://0.0.0.0:9000?mode=listener&latency=500000"
#   con cifrado:   ...&passphrase=MiClaveSegura123&pbkeylen=16

# Móvil en modo LISTENER → la PC llama a la IP que muestra la app
ffplay "srt://192.168.0.50:9000?mode=caller&latency=500000"

# Alternativa oficial de Haivision (reenvía a UDP local para vMix/OBS/decoder)
srt-live-transmit "srt://:9000?mode=listener" udp://127.0.0.1:1234
```

> En ffmpeg, el parámetro `latency` va en **microsegundos**. vMix, OBS, Haivision Media Gateway, Nimble y Wowza reciben el flujo sin configuración extra (MPEG-TS · H.264/HEVC · AAC).

## Verificación realizada

- Una réplica 1:1 de `TSMuxer` + `ADTS` se probó con H.264 High y AAC-LC reales. `ffprobe` y `ffmpeg -err_detect crccheck+bitstream+buffer` decodificaron el resultado sin errores, y los PTS y PCR salieron correctos.
- Una revisión estática verificó las firmas de la API C de libsrt 1.5.4, VideoToolbox, AVFoundation y SwiftUI.
- `MojoLiveTests` cubre CRC, ADTS, sincronismo, continuidad TS, codificación de PTS y ABR. Se ejecuta con ⌘U.

## Pendiente / próximos módulos

- **Módulo 2:** retorno de programa (IFB) y comunicación con el estudio. El retorno para invitados se resuelve vía WebRTC en navegador (sin app).
- Grabación local en paralelo (ISO) para subir en alta calidad cuando se corta la señal.
- Bonding de enlaces (Wi-Fi + celular) con SRT socket groups (`ENABLE_BONDING=ON`).
- Plantillas de zócalo múltiples y lista de invitados precargada.
