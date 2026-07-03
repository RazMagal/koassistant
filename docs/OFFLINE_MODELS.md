# Offline / On-Device AI on Onyx Boox (and other Android e-ink devices)

This guide sets up **fully offline AI** for the Assistant plugin in KOReader on an Onyx
Boox, so features like **Ask**, **Translate**, and **Dictionary** work with no internet and
no API bill.

The idea mirrors how Read Aloud works with a local TTS engine: KOReader's Assistant plugin
has no model of its own — it just makes an HTTP request to a **chat-completions endpoint**.
Normally that endpoint is a cloud service (Gemini, OpenAI, …). For offline use we run a
**small local LLM server on the device** and point the plugin at `http://127.0.0.1:…`
instead. Everything stays on the Boox.

```
KOReader ──HTTP──► http://127.0.0.1:8080/v1/chat/completions ──► local LLM (llama.cpp)
 (Assistant plugin)          (loopback, on-device)               running your GGUF model
```

You can keep your cloud Gemini key configured at the same time and switch between "online"
and "offline" providers in the plugin's Settings dialog — see [Hybrid setup](#hybrid-online--offline) below.

---

## Prerequisites

- An Onyx Boox (or other Android e-ink) device with KOReader installed.
- The Assistant plugin installed at `koreader/plugins/assistant.koplugin`.
- **Enough RAM to hold the model.** A 1–2B model at 4-bit needs ~1.5–2 GB free; a 3–4B
  model needs ~3–4 GB. Most modern Boox devices (3–6 GB RAM) handle a 1–3B model fine.
- A way to install apps and move files (the Boox app store, or sideloading).

---

## Step 1 — Install a local LLM server

You have three options, in order of "most self-contained" to "most powerful":

### Option A — llama.cpp in Termux (recommended, fully on-device)

[Termux](https://f-droid.org/en/packages/com.termux/) is a Linux terminal for Android.
llama.cpp ships an OpenAI-compatible server (`llama-server`) that runs the model on the
device's CPU.

1. **Install Termux from F-Droid** (the Play Store build is outdated — use F-Droid or the
   GitHub releases).
2. Open Termux and update, then install llama.cpp:
   ```bash
   pkg update && pkg upgrade
   pkg install llama-cpp        # provides the `llama-server` binary
   ```
   > If your Termux repo doesn't have the `llama-cpp` package, build it from source instead:
   > ```bash
   > pkg install git cmake clang
   > git clone https://github.com/ggml-org/llama.cpp
   > cd llama.cpp && cmake -B build && cmake --build build -j --target llama-server
   > # binary ends up at ./build/bin/llama-server
   > ```
   > **Important:** clone and build inside Termux's home dir (`~`), *not* in shared storage
   > (`/sdcard`), or Android's `noexec`/permission rules will block the build and the binary.
3. **Download a small GGUF model** into Termux's home directory (see
   [model recommendations](#step-2--pick-a-model)):
   ```bash
   # example: Qwen2.5 1.5B Instruct, 4-bit
   curl -L -o qwen2.5-1.5b-instruct-q4_k_m.gguf \
     https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf
   ```
   This download is the **only** time you need the network. After it finishes, everything
   runs offline.
4. **Start the server**, bound to loopback:
   ```bash
   llama-server -m qwen2.5-1.5b-instruct-q4_k_m.gguf \
       --host 127.0.0.1 --port 8080 \
       --ctx-size 4096 --threads 4
   ```
   Leave this running. It exposes `http://127.0.0.1:8080/v1/chat/completions`.

Then use the **`openai_local`** provider from the sample config (Step 3).

### Option B — Ollama (on-device via Termux, or on your LAN)

Ollama also exposes an OpenAI-compatible endpoint at `http://127.0.0.1:11434/v1/chat/completions`.
On-device, the simplest route is a proot Linux distro inside Termux:

```bash
pkg install proot-distro
proot-distro install debian
proot-distro login debian
# inside Debian:
curl -fsSL https://ollama.com/install.sh | sh
ollama serve &          # starts the server
ollama pull qwen2.5:1.5b
```

Use the **`ollama_local`** provider (make sure its `model` matches what you pulled).

### Option C — A server on another machine on your Wi-Fi (heavier models)

If you have a PC/Mac/home server on the same network, run any OpenAI-compatible server
there — llama.cpp, Ollama, [LM Studio](https://lmstudio.ai), or [Jan](https://jan.ai) —
bound to `0.0.0.0` so the Boox can reach it, then point the plugin at the machine's LAN IP.

This is "offline" from the internet (nothing leaves your network) and lets you run much
bigger, smarter models, at the cost of needing that machine powered on and on Wi-Fi. Use
the **`openai_lan`** provider and set its `base_url` to `http://<PC-LAN-IP>:8080/v1/chat/completions`.

---

## Step 2 — Pick a model

On an e-ink CPU, smaller = snappier. Good instruction-tuned choices in **`Q4_K_M`** GGUF:

| Model | Size (Q4) | Best for |
|-------|-----------|----------|
| **Qwen2.5-1.5B-Instruct** | ~1.0 GB | Great all-rounder for a Boox; strong at translate/summarize |
| **Llama-3.2-1B-Instruct** | ~0.8 GB | Fastest; fine for dictionary/short answers |
| **Llama-3.2-3B-Instruct** | ~2.0 GB | Noticeably smarter if you have the RAM |
| **Gemma-2-2B-it** | ~1.6 GB | Good writing quality |

Rules of thumb:
- Start with **Qwen2.5-1.5B** — best quality-for-speed on Boox-class hardware.
- Prefer a **smaller model that fits comfortably in RAM** over a bigger one that swaps.
- Local models are best for **Ask / Translate / Dictionary**. The heavy book-analysis
  features (**Recap**, **X-Ray**, **Term X-Ray**) send tens of thousands of tokens and will
  be slow or exceed a small model's context — keep those on your cloud Gemini provider (see
  [Hybrid](#hybrid-online--offline)).

---

## Step 3 — Configure the plugin

1. If you haven't already, copy `configuration.sample.lua` to `configuration.lua`.
2. In `configuration.lua`, set the active provider to the offline one and make sure its
   `base_url` matches your server:
   ```lua
   provider = "openai_local",   -- or "ollama_local" / "openai_lan"
   ```
   The sample file already contains `openai_local`, `ollama_local`, and `openai_lan`
   entries with generous timeouts. The important fields:
   ```lua
   openai_local = {
       model = "local-model",   -- llama-server ignores this; any string works
       base_url = "http://127.0.0.1:8080/v1/chat/completions",
       api_key = "no-key-needed",
       timeout = 600,   -- seconds to wait for the (slow) first/last byte
       maxtime = 600,   -- total wall-clock budget for one response
   }
   ```
   > **Why the big timeouts?** On-device generation is slow, and the plugin's default cap is
   > 120 s total — long answers would get cut off. The `timeout`/`maxtime` fields (honored by
   > the `openai` and `ollama` handlers) raise that ceiling.
3. Fully close and reopen KOReader so it reloads the config.

---

## Step 4 — Use it, and turn on Stream mode

1. Start your local server (Step 1) and confirm it's up. From Termux:
   ```bash
   curl http://127.0.0.1:8080/v1/models
   ```
2. In a book, highlight text → **AI Assistant** → **Ask** (or Translate / Dictionary).
3. In the plugin's **Settings dialog**, turn on **Stream mode**. On a local server this
   makes tokens appear as they're generated instead of waiting for the whole answer, so it
   *feels* far faster and side-steps the total-time cap entirely.

---

## E-ink tips

- **Prefer Stream mode** for local models — a gradually filling answer reads better on
  e-ink than a long blank wait, and the plugin uses a `fast` (partial) refresh while
  streaming.
- **Keep answers short.** A lower `max_tokens` / concise prompts = quicker replies. The
  Dictionary and Translate prompts are already short and are the best offline experience.
- **Turn off page-turn animations** (as in the Read Aloud guide) to keep refreshes clean.
- **Long highlights are expensive**: the model must process every token of the highlighted
  passage before it starts answering. On a small local model, keep highlights modest.

---

## Keeping the server alive on Boox (important)

Onyx firmware aggressively kills background apps, which will stop your Termux server. To
keep it running:

1. **Whitelist Termux (and KOReader) from battery optimization.** On Boox: open the app's
   settings / the "Optimize" or power-management screen and set Termux to **"Keep running" /
   don't optimize / allow background activity**. The exact menu varies by firmware — search
   Boox Settings for "optimization" or "background".
2. **Hold a wake lock in Termux** so the CPU stays awake for inference:
   ```bash
   termux-wake-lock       # release later with: termux-wake-unlock
   ```
   (Also available from Termux's notification: "Acquire wakelock".)
3. Keep the Termux notification visible; swiping it away can let Android reap the process.

---

## Troubleshooting

**"Failed to connect" / connection refused.**
The server isn't running or the port/URL is wrong. Confirm with
`curl http://127.0.0.1:8080/v1/models` in Termux. Check `base_url` in `configuration.lua`
matches the port you launched `llama-server` with.

**The answer gets cut off, or you get a timeout/"incomplete content" error.**
Generation exceeded the time budget. Raise `timeout` and `maxtime` in the provider config,
**and/or** enable Stream mode (recommended), **and/or** switch to a smaller/faster model.
Also lower `max_tokens` so answers are shorter.

**First token takes a very long time, then it speeds up.**
That's *prompt processing* — the CPU reading your highlighted text and the prompt before
generating. Shorten the highlight, or avoid the big book-analysis features on a local model.

**Out of memory / the server crashes on load.**
The model is too big for free RAM. Use a smaller model or a smaller quant (e.g. drop from a
3B to Qwen2.5-1.5B, or from `Q4_K_M` to `Q4_0`). Reduce `--ctx-size` (e.g. to 2048).

**KOReader can't reach 127.0.0.1 even though the server is up.**
Loopback between apps normally works on Android. If a firewall/VPN app on the device is
intercepting local traffic, either disable it for loopback or use **Option C** (LAN server)
with the machine's IP instead.

**The server dies whenever the screen sleeps or you leave KOReader.**
See [Keeping the server alive](#keeping-the-server-alive-on-boox-important) — battery
whitelist + `termux-wake-lock`.

**KOReader freezes on the very first AI query.**
This is usually a cold-start stall — the request arrives while the model is still loading, and
the UI blocks. Trigger AI only after the server is ready (`curl http://127.0.0.1:8080/health`
returns `{"status":"ok"}`), and keep **Stream mode on** (it gives a dismissable "AI is
responding" dialog with a Stop button instead of a hard block). If it does freeze, fully
close and reopen KOReader — your reading position is saved. Once the model is warm, subsequent
queries are much smoother.

**Answers are rambling, repetitive, or plainly wrong.**
The local model is too small. A 0.5B model produces low-quality, padded output; step up to
**Qwen2.5-1.5B** for genuinely useful answers (or Llama-3.2-1B as a lighter middle ground).
Reserve the token-heavy features (Recap / X-Ray) for a cloud provider.

---

## Hybrid: online + offline

You don't have to choose. Keep both a cloud provider (your free Gemini flash) and an
offline one in `configuration.lua`. Both appear in the plugin's provider switcher, so you
can:

- use **offline** (`openai_local`) for quick Ask / Translate / Dictionary with no internet,
- switch to **Gemini** for the heavyweight Recap / X-Ray book analysis that needs a large
  context window and stronger reasoning.

Set whichever you use most as `provider = …` (the default), and flip in the Settings dialog
as needed.
