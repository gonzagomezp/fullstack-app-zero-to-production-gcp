# Docker image security checklist

Verified June 2026. Re-verify base image tags and scanner recommendations before
each build. Every service image must satisfy all of the following.

---

## 1. Run as non-root

**Why:** if the process is compromised, root in the container is far more
dangerous (capability abuse, easier breakout). A non-root UID limits the blast
radius.

- **Distroless:** use the `:nonroot` variant — it already runs as UID 65532. No
  extra config needed.
- **Slim/full base:** create and switch to a non-root user explicitly:

  ```dockerfile
  RUN groupadd --system app && useradd --system --gid app --uid 10001 app
  USER 10001
  ```

  Use a numeric `USER` so Cloud Run / Kubernetes `runAsNonRoot` checks pass even
  without `/etc/passwd` lookups. Ensure files the process writes are owned by it.

---

## 2. Minimal final base (distroless or slim)

**Why:** fewer packages = fewer CVEs, smaller image, faster cold starts. A shell
and package manager in the runtime image are attacker tools you do not need.

- Prefer **distroless** (`gcr.io/distroless/...:nonroot`): no shell, no apt, no
  busybox.
- If you need a shell at runtime, use **slim** (`python:3.12.13-slim`,
  `node:22-slim`) and add a non-root user yourself.
- Never ship a full `python:3.12` / `node:22` base as the final stage.

---

## 3. No secrets in image layers

**Why:** image layers are immutable and distributable; anyone with the image can
extract any secret ever copied in, even if a later layer deletes it.

- Never `COPY .env`, key files, or tokens.
- Do not pass secrets via `ARG` (visible in image history/metadata).
- Inject at runtime: Cloud Run `--set-env-vars` / `--set-secrets` (Secret Manager).
- If a build step truly needs a secret, use BuildKit `--mount=type=secret` so it
  is never written to a layer.

---

## 4. `.dockerignore`

**Why:** keeps secrets, VCS history, local junk, and bloat out of the build
context and the image; also speeds builds.

- Always present per service. Exclude `.git`, `.env*`, keys, `node_modules` (when
  installed inside the build), `__pycache__`, caches, tests, CI files, docs.
- See `../assets/dockerignore.template`.

---

## 5. Read-only root filesystem at runtime

**Why:** a writable FS lets an attacker drop binaries or tamper with the app. A
read-only root FS blocks that.

- Cloud Run / `service.yaml`: set the container to read-only and mount a writable
  `emptyDir`/tmpfs only where the app must write (e.g. `/tmp`).
- Ensure the app writes only to explicitly-writable paths.

```yaml
securityContext:
  readOnlyRootFilesystem: true
volumeMounts:
  - name: tmp
    mountPath: /tmp
```

---

## 6. Drop all capabilities

**Why:** containers get a default set of Linux capabilities most apps never use;
dropping them removes privileged operations an attacker could leverage.

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
```

A typical web service needs **no** capabilities. Bind to `$PORT` (>=1024) so you
do not need `NET_BIND_SERVICE`.

---

## 7. `no-new-privileges`

**Why:** prevents the process (and children) from gaining more privileges than it
started with, e.g. via setuid binaries.

```yaml
securityContext:
  allowPrivilegeEscalation: false
```

---

## 8. Pinned base tags

**Why:** floating tags (`:latest`, bare `:3.12`) make builds non-reproducible and
can silently pull a changed/compromised base.

- Pin a specific patch version: `python:3.12.13-slim`, `node:22-slim`,
  `gcr.io/distroless/python3-debian12:nonroot`.
- Use the **Debian-suffixed** distroless tag so a default Debian major bump does
  not surprise you.
- For maximum determinism, pin by **digest** (`@sha256:...`).
- Rebuild on a schedule to absorb upstream patches — pinning means you must
  actively update.

---

## 9. Scan + SBOM in CI (CRA)

**Why:** the EU Cyber Resilience Act (Sep 2026) expects SBOMs and ongoing
vulnerability management; scanning catches known CVEs before deploy.

- Scan every image (Artifact Registry / Container Analysis, Trivy, or Grype);
  fail on high/critical.
- Generate an SBOM (`syft`, `docker sbom`) and retain/attach it.
- Optionally sign (cosign) and enforce with Binary Authorization.

---

## Quick checklist

- [ ] Non-root USER (numeric) or distroless `:nonroot`
- [ ] Minimal final base (distroless / slim), pinned tag (ideally digest)
- [ ] Multistage — no build tooling in final image
- [ ] No secrets in any layer; secrets injected at runtime
- [ ] `.dockerignore` present and excludes secrets/VCS/bloat
- [ ] Read-only root FS, writable tmpfs only where needed
- [ ] Capabilities dropped (`ALL`), `allowPrivilegeEscalation: false`
- [ ] Listens on `$PORT` (8080)
- [ ] Scanned + SBOM generated in CI
