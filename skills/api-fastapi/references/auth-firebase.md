# Firebase auth (verify Firebase ID tokens with firebase-admin)

Alternative to own JWT. The frontend authenticates with Firebase Auth and sends
the Firebase **ID token** as a bearer token; the backend verifies it. No
login/refresh/logout routes — Firebase handles that on the client.

Install: `firebase-admin`.

File locations:
- `app/db/firebase.py` (or `app/functions/firebase.py`) — SDK init.
- `app/dependencies.py` — `get_current_user`.

## settings (additions to app/settings.py)

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    api_key: str
    # Path to a service-account JSON, OR rely on Application Default Credentials
    google_application_credentials: str | None = None
    firebase_project_id: str | None = None
```

## Init pattern (app/functions/firebase.py)

Initialize the Admin SDK exactly once at import/startup.

```python
import firebase_admin
from firebase_admin import credentials, auth as fb_auth
from ..settings import settings

def init_firebase() -> None:
    if firebase_admin._apps:           # already initialized
        return
    if settings.google_application_credentials:
        cred = credentials.Certificate(settings.google_application_credentials)
        firebase_admin.initialize_app(cred)
    else:
        # On Cloud Run / GCP, use Application Default Credentials
        firebase_admin.initialize_app()

def verify_id_token(token: str) -> dict:
    # check_revoked=True also rejects tokens for disabled/revoked sessions
    return fb_auth.verify_id_token(token, check_revoked=True)
```

Call `init_firebase()` in `main.py` (lifespan startup) before serving requests.

## get_current_user dependency (app/dependencies.py)

```python
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from firebase_admin import auth as fb_auth
from .functions.firebase import verify_id_token

_bearer = HTTPBearer(auto_error=False)

async def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> dict:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token")
    try:
        decoded = verify_id_token(creds.credentials)
    except (fb_auth.InvalidIdTokenError, fb_auth.ExpiredIdTokenError,
            fb_auth.RevokedIdTokenError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid Firebase token")
    return decoded            # contains uid, email, claims, etc.
```

Access `decoded["uid"]`, `decoded.get("email")`, custom claims, etc. in routes.

## main.py wiring

```python
from contextlib import asynccontextmanager
from fastapi import FastAPI, Depends
from .functions.firebase import init_firebase
from .dependencies import require_api_key

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_firebase()
    yield

app = FastAPI(lifespan=lifespan, dependencies=[Depends(require_api_key)])
```

Protected routers include `Depends(get_current_user)`; the health router does
not. See `references/api-key.md` for the health-probe tradeoff.
