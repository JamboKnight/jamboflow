# JamboFlow Diagnostic — Launch Guide

Everything is already built. This document is the complete, self-contained path
from "code in this repo" to "live agent on jamboflow.com" — written so you can
follow it without any AI assistant.

## What's in this folder

```
agent/
├── brain/system-prompt.md   The diagnostic methodology. ONE source of truth —
│                            both the website agent and the local agent load it.
├── worker/worker.js         Cloudflare Worker: holds the API key, rate-limits,
│                            streams replies. The browser never sees the key.
├── worker/wrangler.toml     Worker configuration.
├── local/diagnostic.ps1     Offline copilot for this laptop (Ollama).
└── DEPLOY.md                This file.

diagnose.html                The chat page (repo root, ships with the site).
```

## Total cost, restated

| Item | Cost |
|---|---|
| Anthropic API credit | **$5 one-time minimum** (~100–150 full conversations on Haiku) |
| Cloudflare Workers + KV | **$0** (free tier: 100k requests/day) |
| Everything else | Already yours |

An API key is independent of any Claude subscription. Cancelling Claude Code
does not affect it.

---

## Part 1 — Accounts (~15 minutes, the only part requiring you)

**Anthropic API key**
1. Go to https://console.anthropic.com and sign up (any email).
2. Billing → buy $5 of credit. Set a **spend limit** of $5–10/month while you're at it.
3. API Keys → Create Key. Copy it somewhere safe — it's shown once.

**Cloudflare account**
1. Go to https://dash.cloudflare.com/sign-up — free plan, no card needed.
2. That's it. Deployment happens from the command line below.

**Node.js** (needed once, for the `wrangler` deploy tool)
- If `node --version` fails in a terminal, install the LTS from https://nodejs.org.

## Part 2 — Deploy the Worker (~10 minutes)

Open a terminal in `agent/worker/` and run, in order:

```
npx wrangler login
```
(opens a browser window — approve it)

```
npx wrangler kv namespace create RATELIMIT
```
This prints an `id = "…"`. Open `wrangler.toml`, uncomment the
`[[kv_namespaces]]` block at the bottom, and paste that id in.

```
npx wrangler secret put ANTHROPIC_API_KEY
```
(paste your API key when prompted)

```
npx wrangler deploy
```

The deploy prints your Worker URL, something like
`https://jamboflow-diagnostic.<your-subdomain>.workers.dev`. Copy it.

**Smoke test** (PowerShell):
```powershell
Invoke-WebRequest -Method Post -Uri "https://YOUR-WORKER-URL/api/chat" `
  -ContentType "application/json" `
  -Headers @{ Origin = "https://jamboflow.com" } `
  -Body '{"messages":[{"role":"user","content":"We run a small clinic and everything is spreadsheets."}]}'
```
A stream of `data: {...}` events means it's alive.

## Part 3 — Switch on the site (~2 minutes)

1. Open `diagnose.html`, find `const WORKER_URL = "";` (near the bottom)
   and set it to your Worker URL (no trailing slash).
2. Commit and push. GitHub Pages redeploys automatically.
3. Visit https://jamboflow.com/diagnose.html and have a conversation.

**Then link it from the homepage.** Suggested placement: a link from the
Evidence section (next to the teardown link) with copy like
*"Or experience the diagnosis yourself → The Diagnostic"*. A nav link is
optional; Evidence placement keeps it framed as proof, not gimmick.

## Part 4 — The local offline copilot (optional, $0)

One-time, with internet:
1. Install Ollama: https://ollama.com/download/windows
2. `ollama pull llama3.1:8b` (~5 GB download)

Then, forever after, fully offline:
```powershell
cd agent\local
.\diagnostic.ps1
```
It loads the same `brain/system-prompt.md` as the website. Edit the brain once,
both agents change. Expect junior-consultant quality from an 8B model — useful
for rehearsal and note-taking, not a Fable.

---

## Operating notes

**Cost controls already built in**
- Per-visitor cap: 40 requests/day. Site-wide cap: 600/day (≈ $2–3 worst case
  on Haiku). Both are `[vars]` in `wrangler.toml` — change and redeploy.
- Conversations are capped at 12 visitor messages client-side and 30 messages
  server-side; replies are capped at 1024 tokens.
- The Anthropic console spend limit is the final backstop. Set it.

**Upgrading the diagnostician**
The `MODEL` var in `wrangler.toml` is `claude-haiku-4-5-20251001`. If
conversations feel shallow, switch to `claude-sonnet-5` (~5× cost per
conversation, noticeably sharper reasoning) and `npx wrangler deploy`.

**Editing the methodology**
Everything about how the agent thinks lives in `brain/system-prompt.md`.
After editing it, redeploy the worker (`npx wrangler deploy`) — the brain is
bundled into the worker at deploy time.

**Watching usage**
- Anthropic console → Usage shows spend per day.
- Cloudflare dash → Workers → jamboflow-diagnostic shows request counts.

**If the worker misbehaves**
`npx wrangler tail` streams live logs from the deployed worker.

**Custom domain (optional, later)**
Since jamboflow.com's DNS is wherever your registrar is, you can leave the
workers.dev URL as-is — visitors never see it. If you ever move DNS to
Cloudflare, you can route `api.jamboflow.com` to the worker.
