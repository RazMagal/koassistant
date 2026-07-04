# Install — Quick Start

Get the Assistant plugin running in KOReader, then (optionally) go **fully offline** on an
Onyx Boox / Android e-ink device. Two parts, ~5 minutes.

- **Part 1** installs the plugin (needed either way — online or offline).
- **Part 2** is the easy offline path using the [KoLlama](https://github.com/RazMagal/kollama) app.

> Want the deep dive (Termux, Ollama, a LAN server, model choice, e-ink tips)? See
> **[docs/OFFLINE_MODELS.md](docs/OFFLINE_MODELS.md)**. This page is the fast path.

---

## Part 1 — Install the plugin

1. **Download this plugin.** Grab the repo as a ZIP (green **Code → Download ZIP** button on
   GitHub) or `git clone https://github.com/RazMagal/koassistant`.
2. **Copy it into KOReader's plugins folder** as a folder named exactly
   **`assistant.koplugin`**:
   ```
   <KOReader>/plugins/assistant.koplugin/
   ```
   On a Boox, `<KOReader>` is usually `/sdcard/koreader`. So the plugin's `main.lua` ends up at
   `/sdcard/koreader/plugins/assistant.koplugin/main.lua`.
3. **Create your config.** Copy `configuration.sample.lua` to `configuration.lua` in that same
   folder. This file holds your provider/API settings and is **git-ignored** — your keys stay
   private and are never uploaded.
4. **Restart KOReader.** You should now see **AI Assistant** when you highlight text.

At this point the plugin works with any provider you configure (Gemini, OpenAI, …). For a
free cloud option, add a Gemini key to `configuration.lua`. For **offline**, continue below.

---

## Part 2 — Go offline with KoLlama (easy)

[KoLlama](https://github.com/RazMagal/kollama) is a companion Android app that runs a small
LLM on the device and serves an OpenAI-compatible endpoint at `http://127.0.0.1:8080` — no
Termux, no command line.

1. **Install KoLlama.** Download the APK from its
   [latest release](https://github.com/RazMagal/kollama/releases/latest) and sideload it
   (copy over and tap, or `adb install kollama-*.apk`). Allow "install unknown apps" if asked.
2. **Download a model in KoLlama** — start with **Qwen2.5-1.5B** (best quality-for-speed on
   Boox-class hardware). This one-time download is the only step that needs the internet.
3. **Tap Start server.** Leave KoLlama running in the background.
4. **Point the plugin at it.** In `configuration.lua`, set:
   ```lua
   provider = "openai_local",
   ```
   The `openai_local` entry already ships in `configuration.sample.lua`, pre-pointed at
   `http://127.0.0.1:8080/v1/chat/completions` with generous timeouts for slow on-device
   inference. Restart KOReader.
5. **Use it.** Highlight text → **AI Assistant** → **Ask** / **Translate** / **Dictionary**.
   Turn on **Stream mode** in the plugin's Settings dialog — on a local server it makes tokens
   appear as they generate, which reads far better on e-ink.

That's it — Ask / Translate / Dictionary now work with **no internet and no API bill**.

### Verify the server (optional)

Before your first query, confirm the model is loaded so you don't hit a cold-start stall:
KoLlama shows a "healthy" status, or from a terminal with the app forwarded:
```bash
curl http://127.0.0.1:8080/health      # -> {"status":"ok"}
```

---

## Keep both: online + offline

You don't have to choose. Keep your cloud Gemini key **and** `openai_local` in
`configuration.lua` — both show up in the plugin's provider switcher:

- **offline** (`openai_local`) for quick Ask / Translate / Dictionary with no internet,
- **cloud** (Gemini) for the heavyweight **Recap** / **X-Ray** book analysis, which send lots
  of tokens and want a bigger, smarter model.

Set whichever you use most as the default `provider = …` and flip in Settings as needed. Full
details, model recommendations, and troubleshooting: **[docs/OFFLINE_MODELS.md](docs/OFFLINE_MODELS.md)**.

---

## Alternatives to KoLlama

Prefer not to install the app? The offline endpoint can also come from:

- **Termux + llama.cpp** on the device (no extra app) — see
  [docs/OFFLINE_MODELS.md § Option A](docs/OFFLINE_MODELS.md#option-a--llamacpp-in-termux-recommended-fully-on-device).
- **A PC/Mac on your Wi-Fi** running any OpenAI-compatible server, for much larger models —
  use the `openai_lan` provider (§ Option C).

---

## Troubleshooting (quick)

| Symptom | Fix |
|---|---|
| No **AI Assistant** menu | Folder must be named `assistant.koplugin` under `plugins/`; restart KOReader. |
| "Failed to connect" | The local server isn't running. Open KoLlama, tap **Start server** (or check your `base_url`). |
| Answer cut off / timeout | Enable **Stream mode**, and/or use a smaller model. Timeouts are already raised for local providers. |
| KOReader freezes on the **first** query | Cold-start: the model was still loading. Wait for KoLlama to report healthy, keep Stream mode on. If frozen, force-close & reopen KOReader — your place is saved. |
| Answers ramble / are poor | The model is too small (e.g. 0.5B). Step up to **Qwen2.5-1.5B**. Keep Recap/X-Ray on a cloud provider. |

More in **[docs/OFFLINE_MODELS.md § Troubleshooting](docs/OFFLINE_MODELS.md#troubleshooting)**.
