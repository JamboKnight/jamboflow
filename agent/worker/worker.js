/**
 * JamboFlow Diagnostic — Cloudflare Worker backend.
 *
 * Receives the visitor's conversation, prepends the diagnostic brain,
 * calls the Anthropic API with streaming, and pipes the SSE stream back.
 * The API key and the system prompt never reach the browser.
 *
 * Endpoints:
 *   POST /api/chat  { messages: [{ role: "user"|"assistant", content: string }, ...] }
 *   → SSE stream (Anthropic event format, passed through)
 */

import SYSTEM_PROMPT from "../brain/system-prompt.md";

const MAX_MESSAGES = 30; // hard cap; the brain wraps up around 10 visitor turns
const MAX_CONTENT_CHARS = 2000; // per message
const MAX_TOKENS = 1024; // per reply

// Defaults baked in so a dashboard deploy works with zero settings beyond the
// API key secret. Environment variables of the same name override these.
const DEFAULTS = {
  ALLOWED_ORIGINS: "https://jamboflow.com,https://www.jamboflow.com",
  MODEL: "claude-haiku-4-5-20251001",
  IP_DAILY_LIMIT: "40",
  GLOBAL_DAILY_LIMIT: "600",
};
const cfg = (env, key) => env[key] || DEFAULTS[key];

export default {
  async fetch(request, env, ctx) {
    const origin = request.headers.get("Origin") || "";
    const cors = corsHeaders(origin, env);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }

    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/api/chat") {
      return json({ error: "Not found" }, 404, cors);
    }
    if (!cors["Access-Control-Allow-Origin"]) {
      return json({ error: "Origin not allowed" }, 403, cors);
    }

    const parsed = await validateBody(request);
    if (typeof parsed === "string") {
      return json({ error: parsed }, 400, cors);
    }
    const { messages, convoId } = parsed;
    const country = request.cf?.country || null;

    const limited = await checkRateLimit(request, env);
    if (limited) {
      ctx.waitUntil(logTurn(env, {
        convoId, country, kind: "rate_limited",
        userMsg: messages[messages.length - 1].content,
        assistantMsg: null, msgCount: messages.length,
      }));
      return json({ error: limited }, 429, cors);
    }

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: cfg(env, "MODEL"),
        max_tokens: MAX_TOKENS,
        stream: true,
        system: SYSTEM_PROMPT,
        messages,
      }),
    });

    if (!upstream.ok) {
      const detail = await upstream.text();
      console.error("Anthropic API error", upstream.status, detail);
      return json(
        { error: "The diagnostic is temporarily unavailable. Please try again shortly." },
        502,
        cors
      );
    }

    // Tee the stream: one branch to the visitor, one assembled for the log.
    const [toClient, toLog] = upstream.body.tee();
    ctx.waitUntil(logExchange(env, toLog, {
      convoId, country,
      userMsg: messages[messages.length - 1].content,
      msgCount: messages.length,
    }));

    return new Response(toClient, {
      headers: {
        ...cors,
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
      },
    });
  },
};

async function logExchange(env, stream, meta) {
  let assistantMsg = "";
  try {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const events = buffer.split("\n\n");
      buffer = events.pop();
      for (const evt of events) {
        for (const line of evt.split("\n")) {
          if (!line.startsWith("data: ")) continue;
          try {
            const data = JSON.parse(line.slice(6));
            if (data.type === "content_block_delta" && data.delta?.text) {
              assistantMsg += data.delta.text;
            }
          } catch {}
        }
      }
    }
  } catch (e) {
    console.error("log stream read failed", e);
  }
  await logTurn(env, {
    ...meta,
    kind: "exchange",
    assistantMsg,
    diagnosis: assistantMsg.includes("What you came in with") ? 1 : 0,
  });
}

async function logTurn(env, { convoId, country, kind, userMsg, assistantMsg, msgCount, diagnosis = 0 }) {
  if (!env.DB) return; // logging is best-effort; never break the conversation
  try {
    await env.DB.prepare(
      "INSERT INTO turns (convo_id, country, kind, user_msg, assistant_msg, msg_count, diagnosis) VALUES (?, ?, ?, ?, ?, ?, ?)"
    ).bind(convoId, country, kind, userMsg, assistantMsg, msgCount, diagnosis).run();
  } catch (e) {
    console.error("D1 insert failed", e);
  }
}

function corsHeaders(origin, env) {
  const allowed = cfg(env, "ALLOWED_ORIGINS")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);
  const headers = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Max-Age": "86400",
  };
  if (allowed.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Vary"] = "Origin";
  }
  return headers;
}

async function validateBody(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return "Invalid JSON.";
  }
  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length === 0) {
    return "messages must be a non-empty array.";
  }
  if (messages.length > MAX_MESSAGES) {
    return "This conversation has reached its limit. Book the thirty-minute call to go deeper.";
  }
  for (const m of messages) {
    if (
      !m ||
      (m.role !== "user" && m.role !== "assistant") ||
      typeof m.content !== "string" ||
      m.content.length === 0 ||
      m.content.length > MAX_CONTENT_CHARS
    ) {
      return "Each message needs a valid role and content under 2000 characters.";
    }
  }
  if (messages[messages.length - 1].role !== "user") {
    return "The last message must be from the user.";
  }
  const rawId = typeof body.conversation_id === "string" ? body.conversation_id : "";
  const convoId = /^[0-9a-fA-F-]{8,64}$/.test(rawId) ? rawId : "unknown";
  return {
    messages: messages.map((m) => ({ role: m.role, content: m.content })),
    convoId,
  };
}

async function checkRateLimit(request, env) {
  if (!env.RATELIMIT) return null; // KV not bound yet; fail open so testing works
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const day = new Date().toISOString().slice(0, 10);
  const ipKey = `ip:${ip}:${day}`;
  const globalKey = `global:${day}`;

  const [ipCount, globalCount] = await Promise.all([
    env.RATELIMIT.get(ipKey).then((v) => parseInt(v || "0", 10)),
    env.RATELIMIT.get(globalKey).then((v) => parseInt(v || "0", 10)),
  ]);

  if (globalCount >= parseInt(cfg(env, "GLOBAL_DAILY_LIMIT"), 10)) {
    return "The diagnostic has reached its daily capacity. Please come back tomorrow — or book the thirty-minute call directly.";
  }
  if (ipCount >= parseInt(cfg(env, "IP_DAILY_LIMIT"), 10)) {
    return "You've reached today's limit for the diagnostic. If it's been useful, the thirty-minute call is the natural next step.";
  }

  await Promise.all([
    env.RATELIMIT.put(ipKey, String(ipCount + 1), { expirationTtl: 90000 }),
    env.RATELIMIT.put(globalKey, String(globalCount + 1), { expirationTtl: 90000 }),
  ]);
  return null;
}

function json(obj, status, cors) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "content-type": "application/json" },
  });
}
