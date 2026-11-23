# lariska

A MacBook trackpad that talks, sings, raps and plays drums through its haptic motor. No speaker involved. The interface and voice are in Russian.

## Compatibility

- macOS 15 or later
- A Force Touch trackpad: MacBook 2015 or later, or Magic Trackpad 2
- Apple Silicon (Intel is untested)
- Swift 6 toolchain: Xcode 16 or Command Line Tools 16 or later

## Install

```
xcode-select --install          # once, if Swift is missing
git clone https://github.com/wmanzr/lariska.git
cd lariska
./build.sh
./lariska
```

Parrot mode asks for microphone access for your terminal app.

## How it works

- **Motor.** The private `MultitouchSupport` framework is loaded at run time. Each actuation is a short waveform of up to six sine tones, played back to back between 100 Hz and 4 kHz.
- **Voice.** `say` renders the phrase. Pitch comes from YIN, the spectral envelope from Burg linear prediction, and the formants F1 and F2 from envelope peaks tracked across the phrase with dynamic programming. The motor plays both formants and restarts them on every pitch period.
- **Rap.** Syllable onsets are placed on 16th notes by dynamic programming, and the speech between them is time-stretched to fit.
- **Parrot.** `AVAudioEngine` records a phrase and runs it through the same analysis.
- **Touch.** Finger positions from the same trackpad drive notes, drums, vowels and a Morse key.
- **Interface.** An 80×24 terminal canvas at 30 fps; fine graphics use Braille dots and half-block pixels.

The motor never runs above its nominal maximum strength. The framework is private and undocumented, so a macOS update may break it.

## Layout

`Sources/LariskaCore` holds the hardware-free parts: speech analysis, music, rap alignment, Morse and settings. `Sources/lariska` holds the hardware, playback, terminal UI and modes.

## License

MIT
