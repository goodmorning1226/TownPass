> 這份是 2026-11-08 之前的根目錄 README（官方 TownPass 專案說明與本 fork 早期的快速設定），原文保留，
> 只把相對連結改成從 `docs/` 出發。新的專案說明在 [../README.md](../README.md)，地端助理的開發指南在 [../ASSISTANT_README.md](../ASSISTANT_README.md)。

# What is Town Pass?

Town Pass is an open-source project developed by the Taipei City Government. With the growth of smart cities, the demand for digitalization in city management and citizen services continues to rise. As we enter a new digital era, our goal is to involve citizens in the process, combining third-party expertise and innovation to make digital life in Taipei more convenient.

Town Pass is not just an application; it is an open community project. Through open-source, every citizen can participate in the ideation, development, and optimization of the application. This not only enhances citizen engagement and satisfaction but also leverages collective intelligence to continuously improve the application, making it truly serve the people. Furthermore, we hope that various municipalities can widely adopt the open-source framework of Town Pass, integrate it with their existing municipal service systems, and quickly have their own applications to enhance digital governance.

Open source is a key driver of technological progress and social development. Through open-source, Town Pass will become an ever-evolving platform, attracting developers from all backgrounds to contribute. We welcome experts to submit code, report issues, provide suggestions, and even develop new features and creative ideas, working together to perfect Town Pass as we advance toward a smart city.

# Getting Started

For this fork's on-device AI assistant, start with [ASSISTANT_README.md](../ASSISTANT_README.md)
(what it does, architecture, how to run it on a phone), then [team setup](TEAM_LOCAL_SETUP.md),
[current progress and feature files](AI_ASSISTANT_PROGRESS.md), and
[agent handoff](AI_AGENT_HANDOFF.md). Read [AGENTS.md](../AGENTS.md) before changing code.
These additions describe this fork; the upstream introduction and guides remain below.

We highly recommend to read through our [document](https://tpe-guideline.web.app/en/docs/) for more detail.

Here are some quick setup guide.

## Requirement

- [FVM](https://fvm.app/documentation/getting-started/installation): this fork pins Flutter **3.47.6** (Dart 3.13.5) in `.fvmrc`; use `fvm flutter` rather than a global Flutter
- [Android SDK](https://developer.android.com/studio/index.html) (Platform 36, NDK 29.0.13113456) and JDK 17
- [XCode](https://developer.apple.com/xcode/) (for iOS; not yet verified in this fork)
- For the local AI assistant: Python 3.11+ and [Ollama](https://ollama.com/) with `ministral-3:3b`; voice input additionally needs `faster-whisper` (see the setup guide)

Full step-by-step setup, including the emulator and voice, is in [docs/TEAM_LOCAL_SETUP.md](TEAM_LOCAL_SETUP.md).

## Build the Project

Run from the repository root.

1. Install the pinned Flutter and get the packages exactly as locked:

   ``` bash
   fvm install
   fvm flutter pub get --enforce-lockfile
   ```

2. Generate additional needed dart code for the project (generated files are not committed, so this is required after every fresh clone):

   ``` bash
   fvm dart run build_runner build
   ```

3. Check and build:

   ``` bash
   fvm flutter analyze
   fvm flutter test
   python -m unittest discover -s assistant_backend -p 'test*.py'
   fvm flutter build apk --debug
   ```

4. Run without the assistant from your IDE (select an Android device, not Windows desktop) or the command line:

   ``` bash
   fvm flutter run -d <device-id>
   ```

## Run with the Local Assistant (Windows, Android)

One command checks Ollama, starts the backend and speech service in their own windows (reusing any already
running), waits until each is healthy, enables the emulator microphone and then runs the App:

``` powershell
ollama pull ministral-3:3b                     # once; Ollama serves on 127.0.0.1:11434
.\scripts\start_all.ps1 -Model '<converted Breeze-ASR-25 folder>' -DeviceId <device-id>
```

Without `-Model` (or `TOWNPASS_ASR_MODEL`) it runs text-only and says so; `-SkipApp` only starts and checks the services.
The service windows it opens must stay open. The same steps by hand, each in its own terminal:

``` powershell
.\scripts\start_assistant.ps1                                        # assistant backend on 127.0.0.1:8765
.\scripts\start_asr.ps1 -Model '<converted Breeze-ASR-25 folder>'    # voice (optional) on 127.0.0.1:8770
.\scripts\run_assistant_android.ps1 -DeviceId <device-id>            # adb reverse 8765, then flutter run
```

The voice model is converted once with `.\scripts\convert_breeze_asr.ps1` (weights stay outside the repository).
An emulator started from the command line needs `-allow-host-audio` to hear the PC microphone; see the setup guide.
Disable the assistant entirely with `--dart-define=ASSISTANT_ENABLED=false`.
