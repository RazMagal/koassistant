# koassistant — Offline Roadmap

This fork of [omer-faruq/assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)
adds offline / on-device model support for KOReader on Android e-ink devices (Onyx Boox). This
roadmap tracks the **offline-specific** work; general plugin features come from upstream.

Companion app that serves the local model: [KoLlama](https://github.com/RazMagal/kollama).

## Milestones

- [x] **Offline enablement.** Per-provider `timeout`/`maxtime` passthrough (so slow on-device inference isn't cut off by the 120 s cap), an `openai`-handler fix to honor `additional_parameters` (temperature/`max_tokens`), ready-made `openai_local` / `openai_lan` / `ollama_local` providers, and a full Boox setup guide ([docs/OFFLINE_MODELS.md](docs/OFFLINE_MODELS.md)). _Deployed and verified on an Onyx Boox: streaming answers from KoLlama, fully offline._
- [ ] **On-demand local server coordination (open on request, close when KOReader closes).** When an offline provider is selected, have the plugin ensure the local server is up before querying — ping `/health`, and optionally launch KoLlama's server via an Android intent — then signal it to stop when KOReader is closed/backgrounded. Avoids running the model 24/7. _Pairs with KoLlama's on-demand-lifecycle item._
- [ ] **Cold-start guard.** Before sending the real query, poll the local server's `/health` until it's ready (with a spinner + timeout). Directly prevents the first-query UI stall observed on-device when a request lands while the model is still loading.
- [ ] **Graceful "local server offline" handling.** Detect connection-refused to a local provider and show a clear "start your local model server (KoLlama / Termux)" message instead of a generic API error.
- [ ] **Quick online↔offline switch.** A gesture / one-tap toggle to flip the active provider between cloud (e.g. Gemini) and offline (`openai_local`) without digging through settings.
- [ ] **Offline-tuned prompts & guards.** Shorter `max_tokens` for Dictionary/Translate on local models, and guard the token-heavy features (Recap, X-Ray) from tiny local models — warn, or auto-route those to a cloud provider.
- [ ] **Auto-detect local models.** Query the local server's `/v1/models` and offer the loaded model(s) in the model picker instead of a hardcoded name.
- [ ] **Upstream the general fixes.** Open a PR to `omer-faruq/assistant.koplugin` with the two broadly-useful fixes (per-provider timeout passthrough, `openai` `additional_parameters`) so the fork stays lean and everyone benefits.

## Exit criteria

Offline AI that starts on demand, closes when the reader does, fails gracefully when the
server is down, and switches cleanly between cloud and local — all verified on an Onyx Boox.
