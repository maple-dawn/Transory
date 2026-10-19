<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Transory icon">
</p>

<h1 align="center">Transory</h1>

<p align="center">A lightweight macOS translator that works with multiple AI models at once.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <a href="https://github.com/maple-dawn/Transory/releases"><img src="https://img.shields.io/github/v/release/maple-dawn/Transory?include_prereleases" alt="Release"></a>
</p>

<p align="center">
  <a href="README.md">中文</a> · <b>English</b>
</p>

---

## Transory

**Transory** is a native macOS translator. Select text to translate it, translate what's on screen from a screenshot, and send the same sentence to several AI models at once to compare their results.

It works with cloud models such as Claude, OpenAI, Gemini, DeepSeek, OpenRouter, Kimi, Zhipu GLM and Qwen; local models through Ollama and LM Studio; any OpenAI- or Anthropic-compatible endpoint; and you can **sign in with your ChatGPT account** to translate with your subscription instead of an API key.

> The interface is currently in Simplified Chinese.

## Screenshots

<p align="center">
  <img src="docs/images/popover.png" width="480" alt="Selection translation popover">
</p>

<p align="center">
  <img src="docs/images/main-window.png" width="720" alt="Main window with the main translation and model comparison">
</p>

<p align="center">
  <img src="docs/images/settings-services.png" width="640" alt="Settings: choose services per window">
</p>

## Features

- **Selection translation**: select text in any app and press `⌥ D`, or click the small button that appears next to the cursor, to open a translation popover right where you are.
- **One card per model**: the popover shows a result card for each model, streaming as it translates. Cards can be collapsed, copied, read aloud, or used to replace the selected text.
- **Screenshot translation**: press `⌥ S` to capture part of the screen. Text is recognized on-device with Apple Vision (works offline), and the translation can be shown side by side or overlaid on the image.
- **Main window**: type to translate, with other models' results shown below for comparison. Click "采用" (Adopt) to make one the main model.
- **Models per window**: the popover, the menu bar and the main window each have their own list of services. Drag to reorder; the first one is the default.
- **ChatGPT account sign-in**: authorize in the browser, or use the Codex CLI already installed on your Mac.
- **Automatic direction**: if the text is already in the target language (for example, you selected Chinese), it's translated into English instead.
- **Glossary**: set fixed translations for product names, people's names and other terms; matching terms are added to the prompt automatically.
- **History and favorites**: finished translations are saved automatically and can be searched, starred and reopened.
- **Reasoning-model friendly**: optionally hide `<think>` output; custom prompts and temperature are supported.
- **Menu bar quick translate**, **light / dark theme**, **text to speech**.

## Installation

> Requires macOS 14 Sonoma or later.

### Download

Download the latest `Transory-x.y.z.zip` from [Releases](https://github.com/maple-dawn/Transory/releases), unzip it and drag `Transory.app` into your Applications folder.

> [!NOTE]
> Transory isn't signed with an Apple Developer certificate or notarized yet, so macOS says it can't verify the developer the first time you open it. Use any one of these:
>
> - In Applications, right-click Transory, choose Open, then click Open in the dialog;
> - or double-click it once, then click "Open Anyway" at the bottom of System Settings › Privacy & Security;
> - or run in Terminal: `xattr -dr com.apple.quarantine /Applications/Transory.app`
>
> After that it opens normally.

### Build from source

Requires Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/maple-dawn/Transory.git
cd Transory
./scripts/bundle.sh
open build/Transory.app
```

`bundle.sh` builds a release binary, packages it as `build/Transory.app` and signs it ad hoc.

## Usage

| Method | What it does | Default shortcut |
| --- | --- | --- |
| Selection translation | Translate the selected text in a popover next to the cursor | `⌥ D` |
| Translate button | After dragging or double-clicking text, click the small button that appears (can be turned off in Settings) | — |
| Screenshot translation | Capture part of the screen, recognize the text and translate it | `⌥ S` |
| Main window | Type or paste text; see model comparison, history, favorites and the glossary | `⌥ Space` |
| Menu bar | Click the menu bar icon for a quick translation | — |

In the popover, `Esc` closes it and `↩` retranslates the edited source text. Click the pin in the top-left corner to keep the popover open when you click elsewhere.

### First launch

1. **Grant permissions**: a permission guide opens on first launch.
   - **Accessibility**: read the selected text in other apps and replace it.
   - **Screen Recording**: screenshot translation. Reopen Transory after granting it.
2. **Add a service**: open Settings › 模型服务 (Model services), click `+`, pick a service, enter your API key, click "从服务商获取" (Fetch from provider) to choose a model, then click "验证" (Verify).
3. **Choose services per window**: switch between 划词浮窗 (popover), 菜单栏 (menu bar) and 主窗口 (main window) above the service list, and use the toggles to decide which services each window uses.

> If Transory is already listed in System Settings but still shows as not authorized (for example after updating or rebuilding the app), remove it from the list and add it again.

## Supported services

| Type | Services |
| --- | --- |
| Cloud (API key) | Anthropic Claude, OpenAI, Google Gemini, DeepSeek, OpenRouter, SiliconFlow, Kimi, Zhipu GLM, Qwen |
| Local (no key, works offline) | Ollama, LM Studio |
| Custom | Any OpenAI-compatible endpoint, any Anthropic-compatible endpoint |
| Account sign-in | ChatGPT account (built-in browser sign-in / local Codex CLI) |

### About the ChatGPT account service

The ChatGPT account service can connect in two ways:

- **Built-in ChatGPT sign-in**: Transory completes OpenAI's OAuth sign-in in your browser, stores the tokens in the macOS Keychain and calls ChatGPT's Codex service directly.
- **Local Codex CLI**: calls the installed [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`), which manages sign-in itself.

> [!WARNING]
> The built-in sign-in uses the Codex client identity and non-public endpoints. This may not comply with OpenAI's terms of use, and it may stop working whenever those endpoints change. Use it at your own risk; if it stops working, switch to the local Codex CLI.

## Privacy

- API keys and sign-in tokens are stored only in the macOS Keychain.
- Translation requests go directly from your Mac to the providers you choose, never through a third-party server.
- Screenshot text recognition runs entirely on your Mac.
- Transory does not collect any usage data.

## Development

```bash
swift run Transory    # run a debug build
swift test            # run the unit tests
```

You can also open `Package.swift` in Xcode.

```
Sources/
  TransoryCore/      UI-independent core
    Providers/         service adapters (OpenAI-compatible, Anthropic, Gemini)
    Codex/             ChatGPT account: OAuth sign-in, Codex endpoint, Codex CLI
    Translation/       sessions, parallel models, language detection, <think> filtering
    OCR/               Vision text recognition
  Transory/          SwiftUI app: main window, popover, screenshot translation, settings, permission guide
Tests/               unit tests (fake network layer and fake codex script; no real requests)
scripts/
  bundle.sh          package the app
  make-icon.swift    generate the app icon
```

**Adding a service**: OpenAI-compatible services need no code; add a "自定义 OpenAI 兼容" (custom OpenAI-compatible) service in Settings. For another protocol, implement `makeURLRequest(for:)` and `parse(_:)` of `StreamingProvider`, then add a case to `ProviderKind` and `ProviderFactory`.

**UI snapshots**: launch a debug build with `TRANSORY_SNAPSHOT_DIR` set to render the main windows to PNG files and quit. It uses in-memory data and a fake model, and never touches your real settings or the Keychain.

```bash
TRANSORY_SNAPSHOT_DIR=/tmp/shots swift run Transory
```

## Contributing

Issues and pull requests are welcome. Before opening a PR, make sure `swift build` has no warnings and `swift test` passes.

## License

Released under the [MIT License](LICENSE).
