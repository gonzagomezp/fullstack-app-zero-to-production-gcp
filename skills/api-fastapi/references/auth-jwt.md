# Own JWT auth (PyJWT access + refresh, pwdlib argon2id)

Default auth option. Stateless access tokens + rotating refresh tokens.

> **This file is the minimal sketch** (in-memory refresh store, login only). For an
> app with real users — signup with email code, Google login, password reset, login
> throttle, atomic refresh rotation with a grace window, superadmin seed, admin that
> can go Google-only — build from the **`modulos` skill → `login` recipe**
> (`modulos/references/usuarios-login.md`) instead. It supersedes what is below.

- Access token: HS256, short TTL (~15 min).
- Refresh token: HS256, longer TTL (e.g. 7–30 days), **rotated** on every use.
- Passwords hashed with `pwdlib[argon2]` (argon2id).

File locations:
- `app/routers/auth.py` — login / refresh / logout routes + schemas.
- `app/functions/auth.py` — hashing, token mint/verify, rotation logic.
- `app/models/user.py` — user model.
- `app/dependencies.py` — `get_current_user`.

## settings (additions to app/settings.py)

```python
class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    api_key: str
    jwt_secret: str                  # JWT_SECRET (long random)
    jwt_algorithm: str = "HS256"
    access_ttl_minutes: int = 15
    refresh_ttl_days: int = 14
```

## models/user.py

```python
from pydantic import BaseModel, EmailStr

class User(BaseModel):
    id: str
    email: EmailStr
    hashed_password: str
    disabled: bool = False
```

Persist via your selected DB repository (see db-adapters.md). For a stub, an
in-memory dict keyed by email works during scaffolding.

## functions/auth.py — hashing + tokens (framework-agnostic)

```python
import uuid
from datetime import datetime, timedelta, timezone
import jwt
from pwdlib import PasswordHash
from ..settings import settings

_pwd = PasswordHash.recommended()   # argon2id

def hash_password(plain: str) -> str:
    return _pwd.hash(plain)

def verify_password(plain: str, hashed: str) -> bool:
    return _pwd.verify(plain, hashed)

def _encode(sub: str, ttl: timedelta, token_type: str, jti: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": sub,
        "type": token_type,
        "jti": jti,
        "iat": now,
        "exp": now + ttl,
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)

def create_access_token(sub: str) -> str:
    ttl = timedelta(minutes=settings.access_ttl_minutes)
    return _encode(sub, ttl, "access", str(uuid.uuid4()))

def create_refresh_token(sub: str) -> tuple[str, str]:
    jti = str(uuid.uuid4())
    ttl = timedelta(days=settings.refresh_ttl_days)
    return _encode(sub, ttl, "refresh", jti), jti

def decode_token(token: str, expected_type: str) -> dict:
    payload = jwt.decode(
        token, settings.jwt_secret, algorithms=[settings.jwt_algorithm]
    )                                   # raises on expiry/signature/format
    if payload.get("type") != expected_type:
        raise jwt.InvalidTokenError("wrong token type")
    return payload
```

### Refresh rotation

Track valid refresh `jti`s (in your DB or a fast store like Redis) per user.
On refresh: verify the token, confirm its `jti` is still valid, revoke that
`jti`, issue a new access + new refresh (new `jti`). If a revoked `jti` is
re-presented, treat it as theft and revoke all of that user's refresh tokens.

```python
# functions/auth.py (sketch — back with your DB)
_valid_refresh_jti: dict[str, set[str]] = {}   # user_id -> {jti}

def store_refresh(user_id: str, jti: str) -> None:
    _valid_refresh_jti.setdefault(user_id, set()).add(jti)

def rotate_refresh(user_id: str, old_jti: str) -> str:
    valid = _valid_refresh_jti.get(user_id, set())
    if old_jti not in valid:
        _valid_refresh_jti[user_id] = set()        # reuse detected: revoke all
        raise PermissionError("refresh token reuse detected")
    valid.discard(old_jti)
    new_token, new_jti = create_refresh_token(user_id)
    valid.add(new_jti)
    return new_token

def revoke_all(user_id: str) -> None:
    _valid_refresh_jti[user_id] = set()
```

## get_current_user dependency (app/dependencies.py)

```python
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from .functions import auth as auth_fn
from .models.user import User
from .functions.users import get_user_by_id     # your lookup

_bearer = HTTPBearer(auto_error=False)

async def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> User:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token")
    try:
        payload = auth_fn.decode_token(creds.credentials, expected_type="access")
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")
    user = await get_user_by_id(payload["sub"])
    if user is None or user.disabled:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User not found/disabled")
    return user
```

## routers/auth.py — routes + schemas

```python
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, EmailStr
from ..functions import auth as auth_fn
from ..functions.users import get_user_by_email
from ..dependencies import get_current_user
from ..models.user import User

router = APIRouter(prefix="/auth", tags=["auth"])

class LoginRequest(BaseModel):
    email: EmailStr
    password: str

class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"

class RefreshRequest(BaseModel):
    refresh_token: str

@router.post("/login", response_model=TokenPair)
async def login(body: LoginRequest):
    user = await get_user_by_email(body.email)
    if user is None or not auth_fn.verify_password(body.password, user.hashed_password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Bad credentials")
    access = auth_fn.create_access_token(user.id)
    refresh, jti = auth_fn.create_refresh_token(user.id)
    auth_fn.store_refresh(user.id, jti)
    return TokenPair(access_token=access, refresh_token=refresh)

@router.post("/refresh", response_model=TokenPair)
async def refresh(body: RefreshRequest):
    try:
        payload = auth_fn.decode_token(body.refresh_token, expected_type="refresh")
        new_refresh = auth_fn.rotate_refresh(payload["sub"], payload["jti"])
    except Exception:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token")
    access = auth_fn.create_access_token(payload["sub"])
    return TokenPair(access_token=access, refresh_token=new_refresh)

@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(user: User = Depends(get_current_user)):
    auth_fn.revoke_all(user.id)        # invalidate all refresh tokens
```

Note: `/auth/login` and `/auth/refresh` still require the **API key** (global
dependency) but not `get_current_user` — you cannot require a valid access token
to obtain one. They are NOT health endpoints; they are simply the auth bootstrap.
Protected resource routers include `Depends(get_current_user)`.
