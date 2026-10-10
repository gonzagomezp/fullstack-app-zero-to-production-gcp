# Module: reclamos — complaints chatbot on a cheap model

A chat widget where the user tells a bot what went wrong. The bot asks what is missing (one
question at a time), writes the case up so it reads on its own, and **files a complaint** the
team sees in the admin: inbox with unread counter, open → seen → resolved, internal note. The
bot does one job. It runs on the **cheapest stable Gemini model with function calling**, with a
hard cap on usage.

Base shape: web chat for logged-in users, bot living inside `api/`, no WhatsApp. Variants
(decided when applying): separate `agente/` service, anonymous chat, WhatsApp channel.

Reference: a production project (a separate `agente/` service + complaints in `api/` + a chat
widget in the web front + the admin inbox). Its bot ran on **OpenAI** and did more than complaints;
this recipe keeps its complaint design and its hard-won rules, and rewrites the model layer for
Gemini. **Everything marked "new here" does not exist in the reference** and has no production
mileage.

## Depends on

- **`login`**: the complaint is always tied to a proven identity.
- **`superadmin`**: the inbox is one more menu item with its counter.
- Optional: **`mail`** (notify the team on a new complaint), the `webhooks` service (WhatsApp).

## Choices (ask, default first)

1. **Where the bot lives**: inside `api/` as one more router **(default — no extra Cloud Run
   service, no service-to-service auth, the tool writes the complaint directly)** · separate
   `agente/` service as in the reference (more isolated, room to grow into a bigger assistant;
   costs a deploy, an API key and models duplicated across services). See "Variant: separate
   service".
2. **Who can chat**: logged-in users only, widget in the dashboard **(default)** · also
   anonymous visitors (widget on the landing). See "Variant: anonymous".
3. **WhatsApp channel**: no **(default)** · yes. See "Variant: WhatsApp".
4. **Categories**: the product's own list, 4–8 values plus `other`. They only classify for the
   inbox; they never change what the bot requires.
5. **What a complaint hangs from**: nothing — one open complaint per user **(default)** · a
   business entity (order, booking…) — then one open complaint per `(user, entity)`.
6. **Usage caps** (defaults, new here): 30 turns per user per day · 4000 chars per message ·
   global daily token budget that pauses the bot.
7. **Bot name and voice** (the reference's: rioplatense, *de vos*, short, no emojis).
8. **Notify the team by mail on a new complaint?** no, only the counter **(default)** · yes.

## Model layer

- **Model**: a constant in `definition.py`, overridable by env (`ASSISTANT_MODEL`). Pick the
  cheapest **stable** Gemini "flash-lite" that supports function calling, **checked on the
  official models and pricing pages on the day of the build**.
  At the time of writing: `gemini-3.1-flash-lite` (listed stable). `gemini-2.5-flash-lite` is
  cheaper but its page says access to 2.5 models is limited to accounts that already used them.
  Never use a `-preview` or a `-latest` alias here: previews get shut down and aliases change
  behaviour under you.
- **SDK**: `google-genai` (Python). At the time of writing PyPI had 2.25.0, Python ≥ 3.10.
- **API surface**: on that date Google's docs recommended the **Interactions API**
  (`client.interactions.create`) for new projects and kept `generateContent` supported. Both do
  function calling. **Write the adapter from the current official docs** (function calling +
  the chosen API's page), not from this recipe and not from memory: this surface has changed
  more than once.
- Secret: `GEMINI_API_KEY` in Secret Manager, mounted only on the service that runs the bot.

### The adapter contract

Everything model-specific sits behind one small class so the runner never imports the SDK:

```python
class LLM:
    enabled: bool                                   # False when there is no API key → bot says it is unavailable

    async def stream(self, *, system: str, turns: list[Turn], tools: list[ToolSpec],
                     max_output_tokens: int) -> AsyncIterator[Event]: ...
    # Event = {"type": "text", "delta": str}
    #       | {"type": "calls", "calls": [{"id": str, "name": str, "arguments": dict}]}
    #       | {"type": "usage", "input_tokens": int, "output_tokens": int}
    #       | {"type": "error", "message": str}
```

What the adapter must get right (verify each against the docs):
- **Stateless**: send the history yourself on every call and opt out of server-side storage
  (the reference uses `store=False`). The conversation lives in your DB, not the provider's.
- The **system prompt travels separately** from the turns.
- After a tool round, the model must see **its own function call followed by the result** for
  that call id, in order. If the model returns "thought signatures" or similar opaque fields
  with a call, they must go back untouched.
- Tool mode "auto". Arguments validated against the schema by the provider when it offers a
  strict/validated mode.
- Low or minimal thinking. `max_output_tokens` ~1500. Timeout ~120 s.
- Report token usage: the cost cap below needs it.

Test the adapter with a fake stream — never against the real API in CI.

## Bot definition (`definition.py`)

One file holds the model name, the system prompt, the tool schemas and `tools_for()`. It is the
only file to touch to change what the bot is or can do.

### System prompt — static only

**Nothing that changes goes in the system prompt**: no dates, no user name, no session state.
The prefix is then identical across every turn of every user and the provider's implicit
caching makes it cheap. What changes goes **in the current user turn**, appended as a note:

```
[30/09/2026 - 14:20] no me llegó la factura de este mes
[sesión: cuenta identificada, 1 reclamo abierto (R-7KQ2M9) sobre "facturación"]
```

The user's message is **stored without the stamp** (the admin shows what the person wrote).

Sections to write, in the product's voice:
- **Who it is**: a name, that it is the virtual assistant of `<product>`, that it takes
  complaints. It never says it is a person.
- **How it answers**: short, plain text or simple markdown, no emojis, never invents data.
- **Complaints** (adapted from the reference, these five rules are the module):
  1. Ask what is missing so the complaint can be understood on its own: what happened, when,
     about what, amounts, what they already tried. **One question per message**, not an
     interrogation. Do not ask what the app already knows.
  2. Put **everything** in the detail. *"El equipo lee eso, no la conversación entera."*
  3. When it is filed, give the complaint number and say the team will review it.
     **Never promise deadlines, refunds or outcomes.**
  4. **One open complaint at a time** (per entity, if choice 5 says so). Anything the person
     adds later about it goes to that complaint with the other tool — whoever handles it needs
     the whole case in one place.
  5. If they ask about something else, answer in one line and come back to the point.
- **Do not describe buttons or links in prose.** A button exists only when a tool call creates
  it. In the reference, a prompt that described the login button made the model promise it
  without calling the tool one time in three.

### Tools

Two, plus one for the anonymous variant. Schemas are strict (`additionalProperties: false`,
every property required, optional ones nullable).

```python
register_complaint(category: enum[...], summary: str, detail: str, entity_ref: str | None)
add_to_complaint(detail: str, complaint_id: str | None)
request_login()                    # anonymous variant only
```

The tool **descriptions** carry the behaviour; write them in the product's voice and adapt the
examples. Key sentences to keep (from the reference):
- `register_complaint`: *"Antes de llamarla juntá todo lo que puedas… Usala también cuando ya
  tiene un reclamo abierto pero el problema nuevo es de otra cosa: si ya había uno, el sistema
  lo suma ahí solo."*
- `summary`: *"Una línea con el problema, en tus palabras."* `detail`: *"Todo el detalle que
  juntaste… textual lo que dijo si suma."*
- `add_to_complaint`: *"Suma información al reclamo que ya tiene abierto, sin abrir otro… un
  caso partido en tres tickets no lo puede seguir nadie."*

### Gating — `tools_for(state)`

Send only the tools that make sense **in this state**; what does not apply simply does not
exist for the model. Sending everything always makes it offer things it cannot do.

| State | Tools |
|---|---|
| always | `register_complaint` |
| has at least one open complaint | + `add_to_complaint` |
| anonymous variant, not logged in | + `request_login` |

`register_complaint` stays available with a complaint open: removing it would leave a truly
different problem unregistered, and the api will not duplicate anyway. Recompute the tools
**on every round**, since a tool can change the state. A test must tie the registry to the
definitions (every declared tool has a handler and vice versa).

## The loop (`runner.py`)

```
save user message (unstamped) → paused? → caps OK? → load history → build turns (stamp + session note)
for round in range(MAX_TOOL_ROUNDS = 5):
    tools = tools_for(state)
    stream: emit text deltas as they arrive; collect calls
    if round produced text: final_text = that round's text        # the LAST round with text wins
    if no calls: break
    append the model's calls; for each call: run handler → store tool message → append result
save assistant message (final_text or FALLBACK) → record usage → log one line → emit done
```

- **Final text is the last round that had text, not the concatenation.** What the model writes
  before calling a tool is a blind preamble ("dejame ver…"); concatenating put the greeting
  twice in one message.
- `run_tool` catches **every** exception and returns `"ERROR: …"` — a broken tool never takes
  the turn down. Drop the `null`s that strict schemas force before calling the handler.
- **Tools return text for the model, and errors start with `ERROR:`** followed by what to do
  next (*"…preguntale a cuál se refiere y volvé a llamar la tool pasando `complaint_id`"*).
- If the provider fails: answer a fixed `FALLBACK_ERROR` in the bot's voice, store it as the
  assistant message, emit `error` + `done`.
- **One log line per turn**: tools used, tools offered, conversation id. Without the offered
  list, "did not call the tool" and "was never given the tool" look the same.
- If the loop hits `MAX_TOOL_ROUNDS`, log a warning.

### Handlers — "the model is not the guardian"

Each handler re-validates its own precondition and the domain function validates again.

`register_complaint`:
1. `category` in the enum, `summary` ≥ 3 chars → else `ERROR:` naming the valid values.
2. Identity proven → else `ERROR:` telling the model to explain why an account is needed and to
   use `request_login` (anonymous variant; in the base variant the user is always logged in).
3. Call the domain `register(...)` with `summary[:200]`, `detail[:4000]`, channel,
   `conversation_id`. **`user_id` and contact come from the authenticated user, never from the
   model's arguments.**
4. Remember the complaint in the conversation state **from what the api returned**, not from
   what was sent.
5. The returned text **differs when nothing new was created**:
   *"No se abrió un reclamo nuevo: esto se sumó al R-7KQ2M9, que ya tenías abierto… Decíselo
   así, con el número."* Saying "quedó registrado con el número N" to someone who already had N
   sounds like a second ticket, and they wait for two answers.

`add_to_complaint`: no open complaint → `ERROR:`; several open and unclear which → `ERROR:`
with the list, asking the model to ask; the domain answers "closed" or "not yours" → **forget**
that complaint in the state and tell the model to register a new one.

## Data model

### `complaints`

| Field | Type | Rule |
|---|---|---|
| `_id` | str | Internal id. |
| `number` | str | Short human code the bot dictates (`R-7KQ2M9`). Unique index. *(new here — the reference dictates a 26-char ULID.)* |
| `account_id`, `user_id` | str | From the authenticated user. |
| `contact_name`, `contact_email` | str | Snapshot from the user. |
| `category` | enum | Choice 4. |
| `summary` | str | One line, ≤ 200. For the inbox row. |
| `detail` | str | ≤ 4000. What the case was opened with. |
| `notes` | list of `{text, created}` | What was added **after**, in order. Separate from `detail` on purpose: the team must tell what the case opened with from what came later. |
| `entity_ref` | str \| None | Choice 5. |
| `channel` | `"web"` \| `"whatsapp"` | |
| `conversation_id` | str \| None | Lets the admin read the chat behind the summary. |
| `status` | `"new"` \| `"seen"` \| `"resolved"` | "Open" = `new` or `seen`. |
| `note` | str | **Internal** admin note, ≤ 2000. Not the same as `notes`. |
| `created`, `updated`, `seen_at`, `resolved_at`, `handled_by` | | `handled_by` = who moved it. |

Indexes: `(status, created DESC)` · `(user_id, status, entity_ref)` · `number` unique ·
`conversation_id` sparse.

### Conversations

| Collection | Shape |
|---|---|
| `assistant_conversations` | One per `(channel, external_id)` — unique index. `external_id` = `u:<user_id>` when logged in. Holds `open_complaints: [{id, number, summary, entity_ref}]` (a hint for gating; the truth is `complaints`). |
| `assistant_messages` | `conversation_id`, `role` (`user` / `assistant` / `tool`), `content`, `created`; tool messages keep `name`, `args`, `result[:4000]`. |
| `assistant_usage` *(new here)* | `_id` = `<user_id>:<YYYY-MM-DD>` and `global:<YYYY-MM-DD>`: `turns`, `input_tokens`, `output_tokens`, TTL. |

- **Context sent to the model: the last 10 turns, `user` and `assistant` only.** Tool messages
  are not re-injected — their effect already lives in the state.
- **Kept in the DB: 50 turns** per conversation (with tool messages, for debugging), pruned at
  the end of each turn.

## Domain rules (in `functions/complaints.py`, not in the prompt)

```python
async def register(user, *, category, summary, detail, entity_ref, channel, conversation_id) -> tuple[dict, bool]:
    open_one = await complaints_repo.find_open_for(user_id=user.id, entity_ref=entity_ref)
    if open_one is not None:                               # never a second open one
        await complaints_repo.add_note(open_one["id"], note_from(summary, detail))
        return await complaints_repo.get(open_one["id"]), False        # created=False
    …insert with status "new"…
    return saved, True
```

- **The "no duplicate" guarantee lives in the api.** Measured in the reference: asked twice to
  "registralo", the model opened two complaints. A prompt rule is not a guarantee.
- The key is `(user, entity_ref)`. `entity_ref = None` is **its own bucket** (not "any"), still
  capped at one. With Mongo, match the missing field too.
- `add_note(complaint_id, text, user)`: the complaint must belong to that user (else 404, never
  403 — do not confirm it exists) and be open (else **410 Gone**, distinct from a validation
  error so the caller knows to forget it and open a new one).
- Resolving a complaint frees the slot: the next problem opens a new one.

## Api (base variant: bot inside `api/`)

| Method + path | Auth | In | Out |
|---|---|---|---|
| `POST /assistant/chat` | JWT + tenant | `{message}` (≤ 4000) | `text/event-stream` |
| `GET /assistant/history` | JWT | — | last messages of the user's conversation (`user`/`assistant` only) |
| `GET /admin/complaints` | superadmin | `status?`, `category?`, `page` | `{items, total, page, per_page, new}` |
| `GET /admin/complaints/new` | superadmin | — | `{new}` |
| `GET /admin/complaints/{id}` | superadmin | — | the complaint; marks it seen (atomic, only from `new`) |
| `PATCH /admin/complaints/{id}` | superadmin | `{status?, note?}` | the complaint |
| `GET /admin/complaints/{id}/conversation` | superadmin | — | the chat behind it, read-only |

Stream frames, one `data: {json}` line each:

```
{"type":"text","delta":"…"}     {"type":"tool","name":"register_complaint"}
{"type":"action","action":"login"}   {"type":"error","message":"…"}   {"type":"done","text":"…"}
```

Cloud Run buffers nothing special for SSE, but set `Cache-Control: no-cache` and
`X-Accel-Buffering: no`, and make sure the request timeout of the service covers a slow turn.

## Usage caps *(new here — the reference has none on its web channel; it is its biggest gap)*

Checked at the start of the turn, **before** calling the model:

| Cap | Default | On hit |
|---|---|---|
| Message length | 4000 chars | 422 |
| Turns per user per day | 30 | The bot answers a fixed message (*"Por hoy llegamos al límite de mensajes. Si es urgente, escribinos a …"*); **no model call** |
| Tool rounds per turn | 5 | loop stops |
| Output tokens per turn | ~1500 | provider-side |
| Context | 10 turns, no tool results | — |
| Global tokens per day | set from the budget | the bot pauses itself (same fixed message) and logs an error |
| Kill switch | `ASSISTANT_ENABLED` / a flag in the DB toggled from the admin | checked before anything else |

Count the turn with an **atomic** increment-and-read (one upsert), so parallel requests cannot
slip past. Record token usage from the adapter's `usage` event after each turn. A turn that
hits a cap still gets stored as a conversation message, so the admin sees what happened.

One stream per user at a time: the front disables the input while a stream is open; the api
may additionally refuse a second concurrent turn for the same conversation.

## Dashboard

- **Widget**: a floating button that opens a chat panel (bottom sheet on mobile, anchored panel
  on desktop). If `sugerencias` is also installed, the two floating buttons must not overlap:
  put the chat on the **opposite corner** (the reference's chat is bottom-left; the feedback
  button is bottom-right), and both lift above fixed bottom bars.
- **Transport is a Next route handler, not a Server Action** — actions cannot stream. The
  handler adds the API key, the Cloud Run ID token and the user's bearer from the httpOnly
  cookie, calls the api and **pipes the body through unchanged**. The browser only ever talks
  to the dashboard's own origin.
- **Parse SSE incrementally** (a frame can arrive split across chunks); write a small parser
  with its own test.
- Render the assistant's text as **markdown**, sanitized. Format is code, not prompt: the model
  writes markdown and each channel adapts it.
- While a tool runs, show a label per tool (*"Registrando tu reclamo…"*). Add a label for
  **every** tool: the reference has none for the two complaint tools and shows a generic
  "Trabajando…".
- **Actions from the stream never run by themselves**: an `action` frame leaves a button under
  the message, so the person first reads what the bot said.
- History: load `GET /assistant/history` on open; keep the visible messages in `sessionStorage`
  so a reload does not blank the chat.
- First message of the panel, written locally (no model call): what the bot is for, in one line.

## Admin

Same shape as the `sugerencias` inbox (menu item + counter re-fetched on navigation, status
chips, cards, detail, "Marcar resuelto" / "Reabrir", internal note). Differences:
- The card shows `number`, category chip, `summary`, contact, relative date.
- The detail shows `detail`, then **`notes` as a dated list** under it, then a collapsible
  read-only transcript of the conversation.
- A link to the account.
- Search by number: pasting a complaint number jumps straight to the detail.

No reply to the user from the panel (choice made for the base). Variants from the reference if
it is ever needed: reply by mail from the detail with an inbound thread
(Resend + Svix-signed inbound webhook), richer
states (`in_progress`, `dismissed`), team subscriptions to a "new complaint" mail.

## Variant: separate `agente/` service

As in the reference: FastAPI service, its own Dockerfile and deploy, internal ingress.

- The dashboard route handler calls **the agent** (`x-api-key: AGENT_API_KEY` + user bearer +
  ID token); the agent calls **the api** (`x-api-key` + the same user bearer + ID token).
- The agent **never trusts identity from its caller's body**: it validates the bearer against
  the api's `GET /auth/me` on every turn.
- The api exposes `POST /complaints` and `POST /complaints/{id}/notes` (API key + bearer; the
  `user_id` comes from the JWT, never from the payload) and answers `created: bool`.
- **The complaint is written by the api, not the agent**: state lives where the rest of the
  business lives.
- Models are **duplicated on purpose** between the two services (categories live in three
  places). Keep a table of "what to touch on each change" in the agent's `CLAUDE.md` and a test
  that compares the category lists.
- No CORS on the agent at all: it is never reachable from a browser.

## Variant: anonymous chat

- The widget also goes on the landing (through its BFF). `external_id` is a `session_id` the
  browser generates and keeps in `localStorage`.
- Chatting needs no login; **registering does**. `request_login` emits
  `{"type":"action","action":"login"}`; the front shows a button that opens a login dialog
  without leaving the chat; on close it sends the turn *"Ya inicié sesión."* by itself — that
  is the first request carrying the new cookie.
- On login mid-chat, **adopt** the anonymous conversation into the user's
  (a `claim_for_user` step) instead of starting an empty one.
- **Mandatory extra caps** (the client controls `session_id`, so it is worthless as a limit
  key): turns per **IP** per hour and per day (hash the IP with a salt), a lower per-session
  cap, and a TTL that deletes anonymous conversations. None of this exists in the reference.

## Variant: WhatsApp

Add only on explicit request; it is a layer of its own. How the reference did it:
- Meta webhook with HMAC over the raw body, entering through the public `webhooks` service (or
  the project's public proxy) and forwarded to the bot.
- Dedup by `message.id` and a **10-s debounce** that joins several messages into one turn
  (Mongo buffer + Cloud Tasks + a Scheduler sweep).
- No browser → identity by a 6-digit code sent to the email (a send-code tool and a
  verify-code tool, backed by a small OTP store with TTL and attempts).
- No streaming: collect the final text, convert markdown to WhatsApp markup, send via Graph API.
- Bot pause per conversation and "human message" from the panel within Meta's 24-h window.

## Decisions that matter

- **Identity is mandatory for every complaint**, whatever the category. A complaint under an
  unproven email cannot be investigated nor answered.
- **One file defines the bot** (model, prompt, tools, gating).
- **Static system prompt; volatile state in the user turn** — that is what keeps the cached
  prefix cheap.
- **Buttons are created by tool calls, never by text**, and tool texts speak in the future
  ("te dejo un botón") because the front does not act until the person taps.
- **The duplicate guard, the ownership check and the "closed" signal live in the api.**
- **The team reads `summary` + `detail` + `notes`**, not the chat. The transcript is a backup.
- **No mail per complaint by default**: a counter in the admin, as with `sugerencias`.

## Do not copy

- The reference's model layer (OpenAI Responses API, `reasoning.effort`). Same loop, different
  adapter.
- **No rate limit, no spend cap, chat open to anyone** on the reference's web channel.
- **No TTL** on anonymous conversations there.
- Stale comments in the reference that contradict its code — do not port them: one said identity
  depends on the category (the handler always requires it), one said some complaints register
  without an account, two described a navigation bot that no longer existed, and one said the
  `done` frame carries WhatsApp-style text (it carries markdown).
- `GET /complaints/open-count` exists in the reference and nothing consumes it. Wire the
  counter or do not build the endpoint.
- The reference's chat greeting and suggestions never mention complaints. If the bot's one job
  is complaints, the first line must say so.

## Tests

Handlers and domain (real DB, fake LLM): register happy path; invalid category; second
register with one open → `created=False` and a note added; a different `entity_ref` → a new
complaint; `add_to_complaint` with none open, with several open, on a closed one (forgets it),
on someone else's (404); resolving frees the slot; `user_id` never taken from arguments.

Loop (scripted fake LLM): text-only turn; one tool round; final text is the last round's;
provider error → fallback stored; `MAX_TOOL_ROUNDS`; a handler that raises does not break the
turn; registry ↔ definitions match; gating per state.

Caps: the 31st turn of the day makes no model call; kill switch; parallel requests cannot
exceed the cap.

Contract tests for the stores run against the **real DB** and fail in CI if skipped — fakes
drift from the code.

e2e at 390 px with a **fake LLM** behind an env flag: open the widget, file a complaint, see the
number, add a note, see it in the admin with the counter, resolve it.

## Checklist

- [ ] Model chosen from the official pages on the build date; stable, not preview, not alias.
- [ ] Adapter written from current docs; stateless; usage reported; tested with a fake stream.
- [ ] System prompt has no volatile data; date and session state go in the user turn.
- [ ] Tools gated per state and recomputed each round; registry ↔ definitions test.
- [ ] Handlers re-validate; identity and contact from the authenticated user only.
- [ ] Duplicate guard, ownership and "closed" enforced in the domain function.
- [ ] Tool result text differs when nothing new was created.
- [ ] Caps checked before the model call; atomic counter; kill switch works.
- [ ] Chat goes through a route handler that pipes the stream; browser never calls the api.
- [ ] SSE parsed incrementally; every tool has a label; actions never auto-run.
- [ ] Both floating buttons coexist without overlapping, at 390 px.
- [ ] Admin inbox with counter, notes as a dated list, transcript read-only.
