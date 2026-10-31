# UCM2 generation report - Samsung gts28lte

- Source XML: `../../src/device_gts28ltexx/configs/audio/mixer_paths_0.xml`
- Converter command: `mixer2ucm.py --xml ../../src/device_gts28ltexx/configs/audio/mixer_paths_0.xml --card gts28lte --out <DIR> --band wb`
- Voice Call band split: VoiceCall.conf = `wb`, VoiceCallNB.conf = `nb`
- Deterministic generator: no timestamps, stable ordering.

## Path -> device mapping

All paths of the XML, in file order.  `controls` is the number of distinct mixer controls after resolving nested references.

| Android path | controls | UCM device | status |
|---|---|---|---|
| `capture_channel_left` | 2 | HiFi/Headset, HiFi/Mic | feeds device: HiFi/Headset, HiFi/Mic |
| `capture_channel_stereo` | 2 | - | unused |
| `media-handset` | 0 | HiFi/Earpiece | **EMPTY**; feeds device: HiFi/Earpiece |
| `media-speaker` | 4 | HiFi/Speaker | feeds device: HiFi/Speaker |
| `media-headset` | 3 | HiFi/Headphones | feeds device: HiFi/Headphones |
| `media-speaker-headset` | 7 | - | expanded into: speaker-and-headphones |
| `media-bt-sco-headset` | 6 | Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO | feeds device: Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO |
| `incall_nb-handset` | 0 | Voice Call NB/Earpiece | **EMPTY**; feeds device: Voice Call NB/Earpiece |
| `incall_nb-speaker` | 13 | Voice Call NB/Speaker | feeds device: Voice Call NB/Speaker |
| `incall_nb-headset` | 14 | Voice Call NB/Headphones, Voice Call/Headphones | feeds device: Voice Call NB/Headphones, Voice Call/Headphones |
| `incall_nb-headphone` | 14 | Voice Call NB/Headphones, Voice Call/Headphones | feeds device: Voice Call NB/Headphones, Voice Call/Headphones |
| `incall_wb-handset` | 0 | Voice Call/Earpiece | **EMPTY**; feeds device: Voice Call/Earpiece |
| `incall_wb-speaker` | 13 | Voice Call/Speaker | feeds device: Voice Call/Speaker |
| `incall_wb-headphone` | 14 | Voice Call/Headphones | feeds device: Voice Call/Headphones |
| `main-mic` | 3 | HiFi/Mic | feeds device: HiFi/Mic |
| `gain-media-headset-mic` | 3 | HiFi/Headset | feeds device: HiFi/Headset |
| `headset-mic` | 6 | HiFi/Headset | feeds device: HiFi/Headset |
| `media-mic` | 5 | HiFi/Mic | feeds device: HiFi/Mic |
| `media-headset-mic` | 8 | HiFi/Headset | feeds device: HiFi/Headset |
| `media-bt-sco-headset-in` | 6 | Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO | feeds device: Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO |
| `gain-camcorder-mic` | 3 | - | expanded into: camcorder-mic |
| `camcorder-mic` | 8 | - | unused |
| `recording-mic` | 5 | - | expanded into: voice-rec-mic |
| `recording-headset-mic` | 8 | - | expanded into: voice-rec-headset-mic |
| `incall_nb-handset-mic` | 0 | Voice Call NB/Earpiece | **EMPTY**; feeds device: Voice Call NB/Earpiece |
| `incall_nb-speaker-mic` | 12 | Voice Call NB/Speaker, Voice Call/Speaker | feeds device: Voice Call NB/Speaker, Voice Call/Speaker |
| `incall_nb-headset-mic` | 11 | Voice Call NB/Headphones, Voice Call/Headphones | feeds device: Voice Call NB/Headphones, Voice Call/Headphones |
| `incall_wb-handset-mic` | 0 | Voice Call/Earpiece | **EMPTY**; feeds device: Voice Call/Earpiece |
| `incall_wb-speaker-mic` | 12 | Voice Call/Speaker | feeds device: Voice Call/Speaker |
| `incall_wb-headset-mic` | 11 | Voice Call/Headphones | feeds device: Voice Call/Headphones |
| `gain-media-handset` | 0 | HiFi/Earpiece | **EMPTY**; feeds device: HiFi/Earpiece |
| `gain-media-speaker` | 3 | HiFi/Speaker | feeds device: HiFi/Speaker |
| `gain-media-headset` | 4 | HiFi/Headphones | feeds device: HiFi/Headphones |
| `gain-media-speaker-headset` | 7 | - | expanded into: speaker-and-headphones |
| `gain-media-bt-sco-headset` | 2 | Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO | feeds device: Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO |
| `gain-incall_nb-handset` | 0 | Voice Call NB/Earpiece | **EMPTY**; feeds device: Voice Call NB/Earpiece |
| `gain-incall_nb-speaker` | 3 | Voice Call NB/Speaker | feeds device: Voice Call NB/Speaker |
| `gain-incall_nb-headset` | 6 | - | unused |
| `gain-incall_nb-headphone` | 6 | Voice Call NB/Headphones | feeds device: Voice Call NB/Headphones |
| `gain-incall_wb-handset` | 0 | Voice Call/Earpiece | **EMPTY**; feeds device: Voice Call/Earpiece |
| `gain-incall_wb-speaker` | 3 | Voice Call/Speaker | feeds device: Voice Call/Speaker |
| `gain-incall_wb-headset` | 6 | - | unused |
| `gain-incall_wb-headphone` | 6 | Voice Call/Headphones | feeds device: Voice Call/Headphones |
| `gain-media-mic` | 3 | - | expanded into: earpiece-mic, speaker-mic |
| `gain-media-bt-sco-headset-in` | 2 | Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO | feeds device: Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO |
| `gain-recording-mic` | 3 | - | expanded into: voice-rec-mic |
| `gain-recording-headset-mic` | 3 | - | expanded into: voice-rec-headset-mic |
| `gain-incall_nb-handset-mic` | 0 | Voice Call NB/Earpiece | **EMPTY**; feeds device: Voice Call NB/Earpiece |
| `gain-incall_nb-speaker-mic` | 3 | Voice Call NB/Speaker | feeds device: Voice Call NB/Speaker |
| `gain-incall_nb-headset-mic` | 3 | Voice Call NB/Headphones | feeds device: Voice Call NB/Headphones |
| `gain-incall_wb-handset-mic` | 0 | Voice Call/Earpiece | **EMPTY**; feeds device: Voice Call/Earpiece |
| `gain-incall_wb-speaker-mic` | 3 | Voice Call/Speaker | feeds device: Voice Call/Speaker |
| `gain-incall_wb-headset-mic` | 3 | Voice Call/Headphones | feeds device: Voice Call/Headphones |
| `earpiece` | 0 | HiFi/Earpiece | feeds device: HiFi/Earpiece |
| `speaker` | 7 | HiFi/Speaker | feeds device: HiFi/Speaker |
| `headphones` | 7 | HiFi/Headphones | feeds device: HiFi/Headphones |
| `speaker-and-headphones` | 14 | - | unused |
| `voice-earpiece` | 0 | Voice Call NB/Earpiece | feeds device: Voice Call NB/Earpiece |
| `voice-speaker` | 16 | Voice Call NB/Speaker | feeds device: Voice Call NB/Speaker |
| `voice-headphones` | 20 | Voice Call NB/Headphones | feeds device: Voice Call NB/Headphones |
| `voice-earpiece-wb` | 0 | Voice Call/Earpiece | feeds device: Voice Call/Earpiece |
| `voice-speaker-wb` | 16 | Voice Call/Speaker | feeds device: Voice Call/Speaker |
| `voice-headphones-wb` | 20 | Voice Call/Headphones | feeds device: Voice Call/Headphones |
| `hdmi` | 0 | - | **EMPTY** |
| `speaker-and-hdmi` | 0 | - | **EMPTY** |
| `voice-bt-sco-headset` | 8 | Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO | feeds device: Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO |
| `bt-sco-headset` | 8 | - | unused |
| `earpiece-mic` | 8 | - | unused |
| `speaker-mic` | 8 | - | unused |
| `voice-mic` | 0 | - | unused |
| `voice-earpiece-mic` | 0 | Voice Call NB/Earpiece | feeds device: Voice Call NB/Earpiece |
| `voice-speaker-mic` | 15 | Voice Call NB/Speaker | feeds device: Voice Call NB/Speaker |
| `voice-headset-mic` | 14 | Voice Call NB/Headphones | feeds device: Voice Call NB/Headphones |
| `voice-earpiece-mic-wb` | 0 | Voice Call/Earpiece | feeds device: Voice Call/Earpiece |
| `voice-speaker-mic-wb` | 15 | Voice Call/Speaker | feeds device: Voice Call/Speaker |
| `voice-headset-mic-wb` | 14 | Voice Call/Headphones | feeds device: Voice Call/Headphones |
| `hdmi-mic` | 0 | - | **EMPTY** |
| `voice-bt-sco-mic` | 8 | Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO | feeds device: Voice Call NB/BluetoothSCO, Voice Call/BluetoothSCO |
| `bt-sco-mic` | 8 | - | unused |
| `voice-rec-headset-mic` | 8 | - | unused |
| `voice-rec-mic` | 8 | - | unused |

## Empty paths (TODO)

These Android paths only contain a TODO comment.  The UCM devices that reference them carry a `# TODO: empty in Android mixer_paths` comment instead of a sequence; they must be filled in by hand:

- `media-handset` (feeds device: HiFi/Earpiece; referenced by: earpiece)
- `incall_nb-handset` (feeds device: Voice Call NB/Earpiece; referenced by: voice-earpiece)
- `incall_wb-handset` (feeds device: Voice Call/Earpiece; referenced by: voice-earpiece-wb)
- `incall_nb-handset-mic` (feeds device: Voice Call NB/Earpiece; referenced by: voice-mic, voice-earpiece-mic)
- `incall_wb-handset-mic` (feeds device: Voice Call/Earpiece; referenced by: voice-earpiece-mic-wb)
- `gain-media-handset` (feeds device: HiFi/Earpiece; referenced by: earpiece)
- `gain-incall_nb-handset` (feeds device: Voice Call NB/Earpiece; referenced by: voice-earpiece)
- `gain-incall_wb-handset` (feeds device: Voice Call/Earpiece; referenced by: voice-earpiece-wb)
- `gain-incall_nb-handset-mic` (feeds device: Voice Call NB/Earpiece; referenced by: voice-mic, voice-earpiece-mic)
- `gain-incall_wb-handset-mic` (feeds device: Voice Call/Earpiece; referenced by: voice-earpiece-mic-wb)
- `hdmi` (unreferenced)
- `speaker-and-hdmi` (unreferenced)
- `hdmi-mic` (unreferenced)

## Controls without initial value

Controls set inside paths but absent from the top-level initial settings; their reset value is unknown, so the generated DisableSequences carry a `# TODO no default for '...'` comment:

- `AIF1TX1 Input 1`
- `AIF1TX1 Input 1 Volume`
- `AIF1TX2 Input 1`
- `AIF1TX2 Input 1 Volume`
- `AIF2 Mode`
- `AIF3TX1 Input 1`
- `AIF3TX1 Input 1 Volume`
- `AIF3TX1 Input 2 Volume`
- `AIF3TX2 Input 1`
- `ASRC1L Input`
- `ASRC1R Input`
- `HPOUT Digital Volume`
- `HPOUTL Input 1 Volume`
- `HPOUTL Input 2 Volume`
- `HPOUTR Input 1 Volume`
- `HPOUTR Input 2 Volume`
- `IN1L Digital Volume`
- `IN1L Mux`
- `IN1L Volume`
- `IN2 Digital Volume`
- `IN2 Mux`
- `IN2 Volume`
- `ISRC1DEC1 Input`
- `ISRC1DEC2 Input`
- `ISRC1INT1 Input`
- `ISRC1INT2 Input`
- `ISRC2DEC1 Input`
- `ISRC2DEC2 Input`
- `ISRC2INT1 Input`
- `ISRC2INT2 Input`
- `LHPF1 Input 1`
- `LHPF1 Input 1 Volume`
- `SPKOUTL Input 1 Volume`
- `SPKOUTR Input 1 Volume`
- `Speaker Digital Volume`

## Initial settings (BootSequence)

56 controls applied at card boot; first control: `Noise Gate Switch`.

## Unhandled XML elements

None (only `<ctl>`, `<path>` and `<pcmdai>` were present).

### pcmdai link hints (recorded, not converted)

- playback_link=4
- playback_deep_link=3
- capture_link=0
- baseband_link=1
- bluetooth_link=2

## Validation

Levels of validation possible for generated UCM2 files:

1. structural  - validate_ucm.py: balanced braces/quotes, known keywords,
   cset argument shape.
2. alsa-lib grammar - every generated file loaded with snd_config_load()
   from libasound (Docker debian:trixie, libasound2).
3. full UCM import - alsaucm against a real or snd-dummy card; requires a
   kernel ALSA driver, impossible inside a plain container.

**Achieved for this generation: level 1 PASS (structural, validate_ucm.py) + level 2 PASS (alsa-lib snd_config_load, Docker debian:trixie arm64, alsa-ucm-conf 1.2.14); level 3 NOT achieved: alsaucm needs a kernel sound card, absent from the container**
