# API key dependency

Every endpoint requires a valid `X-API-Key` header equal to a server-side
secret. Apply the dependency globally so no route is accidentally left open.

## settings (app/settings.py)

```python
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    api_key: str  # API_KEY in env

settings = Settings()
```

## The dependency (app/dependencies.py)

```python
import secrets
from fastapi import Depends, HTTPException, status
from fastapi.security import APIKeyHeader
from .settings import settings

# auto_error=False so we can return 401 with our own message
_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

async def require_api_key(api_key: str | None = Depends(_api_key_header)) -> None:
    if api_key is None or not secrets.compare_digest(api_key, settings.api_key):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
        )
```

Use `secrets.compare_digest` to avoid timing attacks.

## Applying it globally (app/main.py)

Attach the dependency to the whole app so every router inherits it:

```python
from fastapi import FastAPI, Depends
from .dependencies import require_api_key

app = FastAPI(dependencies=[Depends(require_api_key)])
```

App-level `dependencies` run on **every** request to every included router.
Combined with auth on the protected routers, you get: API key everywhere +
auth everywhere except health.

## Exempting the health probe (the tradeoff)

App-level dependencies cannot be selectively disabled per-route. If the health
endpoint must be reachable by a Cloud Run / load-balancer probe that cannot send
`X-API-Key`, choose one:

### Option A — keep API key on health, configure the probe header
Best when the platform supports custom probe headers (e.g. set
`X-API-Key` on the HTTP startup/liveness probe). Nothing special in code.

### Option B — exempt health from the API key
Do NOT put the API-key dependency at app level. Instead apply it per-router and
simply leave it off the health router:

```python
# main.py
app = FastAPI()                                   # no global dependency
app.include_router(health.router)                 # no api-key, no auth
app.include_router(
    items.router,
    dependencies=[Depends(require_api_key), Depends(get_current_user)],
)
```

Keep an exempt `/health` to a bare `{"status": "ok"}` with no sensitive data.
For richer diagnostics, add a separate `/status` that DOES require the API key
(and optionally auth). Document the choice in README.md.
