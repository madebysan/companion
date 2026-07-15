<h1>Companion</h1>

<p>Select text in any Mac app, run a writing command, and replace it in place.<br>
Use your own cloud API key or a local model.</p>

<p><strong>Version 0.2.2</strong> · macOS 13+ · Apple Silicon & Intel</p>

<p>
  <img src="https://img.shields.io/badge/Swift-f05138" alt="Swift">
  <img src="https://img.shields.io/badge/AppKit-0066cc" alt="AppKit">
  <img src="https://img.shields.io/badge/macOS-000000" alt="macOS">
  <img src="https://img.shields.io/badge-BYOK-111827" alt="Bring your own key">
</p>

<p><a href="https://github.com/madebysan/companion/releases/latest">Download Companion</a></p>

![Companion command palette](assets/social-preview.png)

Companion is a menu bar app for quick writing tasks in Mail, Notes, Notion, Slack, browsers, code editors, and most places where you can select or enter text. Run a saved action such as "Fix Grammar" or "Shorten Text," or type a one-off instruction when the edit is specific.

https://github.com/user-attachments/assets/dff2816f-f1be-4334-ae09-69ea52ab66cf

## How it works

Select text in another app and press `Cmd + Shift + E`. Choose a saved action or type an instruction such as `make this warmer and shorter`. Companion sends the request through the route you chose, replaces the selection, and keeps the result on your clipboard.

If nothing is selected, the instruction creates new text and inserts it at the cursor. Saved actions can handle recurring work such as grammar fixes, shortening, tone changes, or turning rough notes into an email.

## Models and privacy

Each action can use a local LM Studio model, a fal/OpenRouter route, or a direct OpenAI, Anthropic, or DeepSeek connection. Settings is where you add keys, choose the models that appear in the picker, and edit saved actions.

![Companion direct provider settings](assets/screenshots/settings-providers.png)

![Companion saved action settings](assets/screenshots/settings-actions.png)

![Companion local model and routing settings](assets/screenshots/settings-local-routing.png)

There is no Companion server, account, analytics, or telemetry. LM Studio requests stay on your Mac. Cloud requests send the selected text and instruction directly to the provider route you chose. Companion stores settings, generated results, and routing metadata locally; it does not retain the original selected text or image bytes in history.

## Install

1. Download the DMG from [Releases](https://github.com/madebysan/companion/releases/latest).
2. Drag `Companion.app` to Applications and open it from the menu bar.
3. Choose a provider during onboarding or configure one later in Settings.
4. Grant Accessibility and Input Monitoring when macOS asks, then relaunch Companion.

Accessibility lets Companion copy a selection and paste the result. Input Monitoring lets the shortcut work while another app is focused. If macOS keeps an old permission entry after an update, remove Companion from both permission lists, add it again, and relaunch.

## Build from source

```bash
git clone https://github.com/madebysan/companion.git
cd companion
swift build -c release --package-path Companion --arch arm64 --arch x86_64
./script/build_and_run.sh --verify
```

To produce a signed DMG on a configured development Mac, run `./script/build_dmg.sh`. Add `--notarize` for the public release path.

Companion requires macOS 13 or later on Apple Silicon or Intel. LM Studio and cloud provider keys are optional; at least one local or remote model route is required to generate text.

## Tech stack

- Swift and AppKit
- Swift Package Manager
- [HotKey](https://github.com/soffes/HotKey) for global shortcuts
- LM Studio and OpenAI-compatible chat routes
- Anthropic Messages API for direct Claude support

## License

[MIT](LICENSE)

Made by [santiagoalonso.com](https://santiagoalonso.com)
