---
name: e2e-testing
description: Doctrine for building an end-to-end test suite that runs the real app against a real backend and a disposable database — layer startup and readiness, seeding through the production API, one-shot login with saved session state, state the UI cannot reach, doubles for third parties that call back (payment webhooks), clock control for TTLs, isolation under parallelism, and CI wiring. Use when setting up e2e/integration tests from scratch, adding a browser-driven test layer, deciding what to mock vs run for real, testing a payment or webhook flow end to end, or diagnosing flaky/skipped e2e. Stack-agnostic; examples in Playwright + Next.js + FastAPI + MongoDB.
---

# End-to-end testing

The pattern here is for a suite that **runs the real application against a real
backend**, in a browser, with a database it can throw away. Not a smoke test and
not integration tests with mocks: the point is to exercise the paths where money
and identity move, through the same code that runs in production.

Everything below is stack-agnostic doctrine. The examples are Playwright +
Next.js + FastAPI + MongoDB because that is where it was hardened; substitute
freely — Cypress, Rails + Postgres, Django, whatever. What must not be
substituted is the reasoning.

**This skill is doctrine, not a generator.** Do not scaffold files from it
unprompted. Apply the principles to the project at hand.

---

## 0. First, decide what belongs in e2e at all

E2E is the most expensive test you can write: slowest to run, hardest to debug,
most likely to go flaky. Spend that budget where nothing cheaper can go.

| Belongs in e2e | Belongs elsewhere |
|---|---|
| Money moving (checkout, refund, payout) | Pure logic → unit |
| Identity (signup, login, session, permissions) | Error-mapping matrices → unit test of the handler |
| Flows crossing service boundaries (webhook → DB → UI) | Rendering variants → component test |
| Irreversible actions (delete, transfer, burn) | Anything you can assert without a browser |

A useful test: *if this broke, would a user lose money, access, or data?* If not,
it probably does not need a browser.

Corollary: when a bug turns out to be in one layer, write the cheap test there
too. E2E proves the wiring; unit tests pin the reason.

---

## 1. The database is disposable, not cleaned

Do not write teardown that deletes what the tests created. Teardown is code that
runs when things go well — exactly the wrong time, since the run you most want
to inspect is the one that failed.

- **CI**: an ephemeral database container per job. It dies with the job. Nothing
  to clean.
- **Local**: point at a *separate* database (`MONGO_DB=myapp_e2e`,
  `DATABASE_URL=...?dbname=myapp_e2e`), never the dev one.

The consequence, and it is the important half: **locally the data accumulates**,
so the suite must tolerate a dirty database. Nothing may assume "I start from
zero". Seeds get unique names or accept collisions; the admin account is
created-or-reused; the test user is registered-or-logged-in.

This is not a compromise, it is a feature. A suite that only passes on a virgin
database is a suite that will fail the first time someone runs it twice.

---

## 2. Layers, and who waits for whom

Name every process and decide who starts it and how the next one knows it is
ready. A typical stack:

| Layer | Started by | Readiness signal |
|---|---|---|
| Database | CI service container / `docker run` | container healthcheck |
| Backend | the CI workflow, backgrounded | poll an endpoint (`/openapi.json`, `/health`) |
| Frontend | the test runner's `webServer` | poll its own URL |
| Third-party doubles | the workflow, **before** the backend | poll their health route |
| Seed data | runner's global setup | it runs to completion before any test |
| Session | a dedicated setup test | other tests declare a dependency on it |

Two rules that are not negotiable:

**Wait on a signal, never on a duration.** `sleep 10` passes on your laptop and
fails on a loaded runner. Poll for the thing you actually need, with a bounded
number of attempts and a clear error when it never arrives.

```bash
for i in $(seq 1 30); do
  curl -sf http://localhost:8000/openapi.json && exit 0
  sleep 2
done
echo "API did not start" && exit 1
```

**Run the frontend built as production**, not in dev mode. Dev servers hide
hydration timing, bundle differences, and build-time environment inlining. Which
leads to a trap worth knowing: with server-rendered frameworks, a button exists
in the HTML before the client framework attaches its handler, so a click can land
early and silently do nothing. Fill a *controlled* input and assert the value
stuck before clicking — that only holds once hydration is done.

---

## 3. Three layers of tests, chosen by filename

Split the suite into projects/suites so that a broken login does not produce
twenty identical failures.

```ts
projects: [
  { name: "setup",  testMatch: /.*\.setup\.ts/ },
  { name: "public", testMatch: /.*\.public\.spec\.ts/ },
  { name: "authenticated",
    testMatch: /.*\.auth\.spec\.ts/,
    use: { storageState: ".auth/user.json" },
    dependencies: ["setup"] },
]
```

- **The filename decides the layer.** No registry to maintain: name the file with
  the right suffix and it lands in the right project.
- **Log in once**, in `setup`, and persist the session (cookies + local storage)
  to a file the other tests load. Logging in per test is N round trips to your
  identity provider and N chances to go flaky, for a flow already proven once.
- **`dependencies` makes failure legible**: when login breaks, the authenticated
  tests *do not run* rather than failing twenty times with a misleading message.
- **Public tests must not depend on setup.** When identity breaks, they still
  pass, and that tells you the app is fine and only auth is broken.

Session artifacts and seed files are build outputs: gitignore them.

---

## 4. Seed through the production API, never into the database

Create fixtures by calling the same endpoints the product calls: create the
resource, then its children, then publish it.

Why it matters more than it looks:

- If a backend invariant breaks, it breaks **in setup**, loudly, instead of
  producing an impossible fixture that makes an unrelated test fail later for the
  wrong reason.
- There is no second schema to maintain. A hand-written database fixture drifts
  from the model and nobody notices until a test starts lying.
- IDs, slugs and derived fields come out the way production makes them.

Write what was created to a file (`.seed.json`) and have specs read it. Keep the
seed minimal: the shared baseline everyone needs. Anything a single spec needs to
own, that spec seeds for itself (see §7).

---

## 5. State the UI cannot reach

Every real app has state that is required to test and impossible to produce by
driving the browser. Three kinds, three answers:

**(a) State in an external identity provider.** Provision it through that
provider's own public API, not through your UI. Doing it through the signup form
"works" until it fails, and then the only symptom is your app's generic error
message — which cannot distinguish a wrong password from a disabled provider from
a misconfigured key. Calling the provider directly gives you its error code, and
you translate that code into *what the operator must change*.

**(b) State in your own database that needs an out-of-band step** — a phone
verified by SMS code, an email confirmed by link, a KYC approval. Seed it through
**the closest production path that exists**. If another part of the system
legitimately sets that flag server-to-server, use that. Never add
`POST /test/make-me-verified`: an endpoint that exists only for tests is
unmaintained by definition and will eventually ship enabled.

**(c) State that only exists when time passes** — see §8.

The rule that generalizes: **prefer the real path, however indirect, over a
shortcut that only tests use.**

And the trap that costs a day if you miss it: **if CI drops the database every
run, nothing living in that database can be "pre-created" by hand.** An account
set up manually in a provider's console does not carry the flags that live in
*your* tables. Everything in your database is seeded every run, always.

---

## 6. What to run for real, what to double

Four tiers. The line is not "internal vs external", it is *can I drive it
deterministically, and what does it cost me*.

| Kind | Do | Why |
|---|---|---|
| Your own backend and database | **Real, always** | Mocking your own system means testing your mock |
| Third party, deterministic and free | Real | It is part of the flow and it does not bite |
| Third party, costs money or is non-deterministic (LLMs, SMS) | Intercept at the browser boundary | A test that fails because a model chose differently tells you nothing about your frontend |
| Third party you cannot complete (a real card payment) | Run to the boundary, plus a **double** (§6.1) | Two tests, two different truths |

For interception, prefer the network boundary closest to the browser (route
interception with a canned response) over dependency injection. You test the code
that parses and renders the response, which is the part that breaks.

### 6.1. The third party that calls *you* back

This is the case most suites give up on, and it is where the money is.

A payment provider does not return the result through the browser. The browser
gets redirected somewhere pleasant; the truth arrives later, as a server-to-server
webhook. Without a double you can only prove *that you sent someone to pay* —
never that **getting paid confirms the order, sends an email, and issues a receipt**.

Build a small fake that speaks the provider's dialect:

- Implement **only the endpoints your integration actually calls** — usually
  three to five. Read your own client to enumerate them; do not model the
  provider.
- Serve a **minimal hosted-checkout page with a "Pay" button**, so the browser
  test flows through it like a person would.
- On pay, the fake **calls your webhook, signed the way the real one signs it**.
  Forging the signature is a few lines of HMAC and it means your real signature
  verification stays in the path.
- Expose an **introspection route** (`/__state`) so tests can assert what the
  provider received: payments created, refunds issued.
- Add a **direct pay route** for scenarios that must not go through a browser
  (paying after the order expired).

Two design decisions that matter more than the code:

**Model the strictest plausible semantics, not the friendliest.** If the real API
documents `PUT` as a replace, make the fake replace. A permissive double is a
double that certifies bugs. (Concretely: a partial `PUT` that dropped
`external_reference` and `notification_url` from a payment preference produced
charges that could not be attributed to any order — no confirmation, no email, no
refund. A lenient fake would have passed.)

**Keep the real-provider test too.** The double can never prove the provider
accepts your payload. Keep the shallow test that runs against the real sandbox
and stops at the redirect, and gate the two on a flag so they are mutually
exclusive:

```ts
// deep test, needs the double
test.skip(!usingFake, "needs the payment double");
// shallow test, needs real credentials
test.skip(usingFake, "runs against the real provider");
```

The payoff is large: with the double, the paid flow needs **no credentials at
all** and stops being the one path nobody can test.

Configuring this requires exactly one production seam: the provider's base URL
must come from configuration, defaulting to the real one. That is legitimate
config (it also points at sandboxes and proxies), not a test backdoor.

---

## 7. Isolation under parallelism

Run tests in parallel and share one account — but then **every spec owns its
data**.

The failure mode is quiet: a spec asserts "the user now has N+1 orders", another
spec buys concurrently, and the first fails intermittently with a number nobody
can explain.

- Assert on **the entity this test created**, identified by an id it captured
  (`order_id`, `reference`), never on counts or "the first row".
- If a spec needs a product, a booking slot or a tenant it will mutate, **seed one for
  that spec**. Sharing the baseline fixture for a destructive test is how you get
  order-dependent failures.
- Locate elements by data the test knows (a code read back from the API), not by
  position on screen.

The discipline is the same one that makes production code concurrent-safe, and it
is worth paying: a suite that only passes with `workers: 1` will be abandoned the
moment it gets slow.

---

## 8. Time: TTLs, expiry, schedulers

Anything with a deadline — a held reservation, a payment link, a token — needs a
test where the deadline actually passes. Waiting seven real minutes is not an
option, and asserting "the timer component renders 04:59" tests nothing.

Make the windows configurable, and the background worker's interval too:

```python
ORDER_TTL_MINUTES = env_minutes("ORDER_TTL_MINUTES", 5)   # 0.3 in e2e
EXPIRE_JOB_SECONDS = settings.expire_job_seconds          # 60 → 3 in e2e
```

Three cautions:

1. **This is business configuration, not a test hook.** Changing a reservation
   window should not require a deploy anyway. That is what makes it acceptable.
2. **Guard the desync.** These numbers are usually also written in UI copy,
   emails, and prompts ("we hold your cart for 5 minutes"). Overriding them in
   production without changing the copy makes the product lie. Say so, in a
   comment, at the definition.
3. **Gate the specs on a flag** (`E2E_SHORT_TTL=1`) so that running the suite
   against a normally-configured environment skips them instead of hanging.

Then the test asserts what the person sees when time runs out: the countdown
reaching zero, the confirm button disabled, the message explaining what happened
to their reservation.

---

## 9. Missing credentials: skip, never disable

Two things look alike and are opposites:

```ts
test.skip(!process.env.PROVIDER_TOKEN, "needs a sandbox token");  // honest
```
```yaml
if: false   # the job is off and the dashboard is green
```

The first is truthful: without that credential the path cannot be exercised, and
the rest of the suite still has value. The second hides that **nothing** is being
tested, and the comment explaining why goes stale within weeks — usually with the
wrong diagnosis, because whoever wrote it never reproduced the failure.

Same idea for a suite that needs an optional service: skip when it is absent
locally, but **fail when `CI` is set**. A contract that skips itself in CI is not
a contract.

```python
if error:
    if os.getenv("CI"):
        pytest.fail(f"CI without Mongo at {uri}: {error}")
    pytest.skip("no Mongo; start one to run these")
```

If a job is genuinely blocked, prefer a first step that **fails with the name of
what is missing** over silently not running:

```yaml
- name: Check secrets
  run: |
    missing=""
    for v in PROVIDER_KEY PROVIDER_SECRET; do
      [ -z "${!v}" ] && missing="$missing $v"
    done
    [ -n "$missing" ] && { echo "::error::missing:$missing"; exit 1; }
```

(The `secrets` context is not available in a job-level `if`; job-level `env` plus
a step-level check is the way.)

---

## 10. Diagnostics are part of the test

A failing unit test points at a line. **A failing e2e can be broken in any of six
layers**, and by default it says "timeout of 30000ms exceeded", which is the least
useful sentence in testing.

Every place a test can get stuck should collect the evidence *its own layer* can
see, and say what has been ruled out:

- current URL, cookies present, console errors, visible error text
- failed HTTP responses — **all of them**, not filtered by a path prefix (server
  actions and RPC posts often go to the page's own URL, so a naive filter hides
  the actual error)
- the state of the double: what it received, what it returned
- and the sentence that saves the most time: *what is already known to be fine.*
  "The account exists and the password is correct — verified before the browser
  opened — so the problem is the build or the backend credentials."

When a failure message is ambiguous, that is a bug in the test. Fix it by moving
the check to where the real error code lives, even if that means calling an API
directly instead of driving the UI.

Also: `retries: 1` in CI with a trace on first retry, and upload the report as an
artifact on failure. And put a **timeout on the job** — a hung run that holds a
runner for 45 minutes costs more than the failure it was hiding.

Finally, remember the test's own timeout outranks any expectation's: an `expect`
waiting 90s inside a test with a 30s budget fails at 30s, with a message about
the wrong thing.

---

## 11. Never touch production

Say it in the workflow, out loud, in a comment. Everything ephemeral: database in
a container, backend from source, frontend built in the job, third parties
doubled. The only real external thing should be an identity provider's test
project, and even that should hold nothing but throwaway accounts.

Secrets: only what genuinely cannot be faked. Every credential you can remove
from CI is one that cannot leak from CI — which is another reason the payment
double is worth building.

---

## Checklist

1. Disposable database, no teardown; separate database locally; seeds tolerate dirt.
2. Every layer waits on a signal, never a duration.
3. Frontend built as production, not dev.
4. Filename decides the project; login once into saved session state; `dependencies` so auth failure does not spray.
5. Seed through the real API; write a seed file; specs read it.
6. UI-unreachable state seeded through the closest production path; no test-only endpoints.
7. Own backend real; expensive/non-deterministic third parties intercepted; call-back third parties doubled with strict semantics — and keep the shallow real-provider test.
8. Parallel-safe: assert on entities this test created; destructive specs seed their own fixtures.
9. TTLs and worker intervals configurable; expiry specs gated on a flag; guard against copy desync.
10. Missing credentials skip with a reason; never `if: false`; optional services fail in CI.
11. Every failure path collects its layer's evidence and states what is ruled out.
12. Job timeouts, retry with trace, report uploaded on failure.
