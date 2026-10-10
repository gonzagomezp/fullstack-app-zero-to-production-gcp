# Skeleton — folder tree + working example files

Adjust to the selected auth (jwt/firebase) and db (firestore/postgres/mongo/none).

## Folder tree (jwt + a db)

```
app/
  __init__.py
  main.py
  settings.py
  dependencies.py
  routers/
    __init__.py
    health.py
    auth.py            # jwt option only
    items.py
  functions/
    __init__.py
    auth.py            # jwt option only
    items.py
  models/
    __init__.py
    user.py
    item.py
  db/                  # omit entirely if db=none
    __init__.py
    firestore.py       # or postgres.py / mongo.py
    items_repo.py
.env
.gitignore
requirements.txt
CLAUDE.md
README.md
requirements.md
```

## app/settings.py

```python
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    api_key: str                       # API_KEY
    jwt_secret: str = "change-me"      # jwt option
    jwt_algorithm: str = "HS256"
    access_ttl_minutes: int = 15
    refresh_ttl_days: int = 14

settings = Settings()
```

## app/dependencies.py

```python
import secrets
from fastapi import Depends, HTTPException, status
from fastapi.security import APIKeyHeader
from .settings import settings
# from .functions import auth as auth_fn   # jwt option — see references/auth-jwt.md

_api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

async def require_api_key(api_key: str | None = Depends(_api_key_header)) -> None:
    if api_key is None or not secrets.compare_digest(api_key, settings.api_key):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or missing API key")

# get_current_user lives here too — see the selected auth reference.
```

## app/routers/health.py (NO auth; see api-key.md for probe note)

```python
from fastapi import APIRouter

router = APIRouter(tags=["health"])

@router.get("/health")
async def health() -> dict:
    return {"status": "ok"}
```

## app/functions/items.py (logic only — no FastAPI imports)

```python
from ..models.item import Item
# from ..db.items_repo import list_items as repo_list, create_item as repo_create

async def list_items() -> list[Item]:
    # return await repo_list()        # when a db is selected
    return [Item(id="1", name="example")]

async def create_item(name: str) -> Item:
    item = Item(id="generated-id", name=name)
    # await repo_create(item)
    return item
```

## app/models/item.py

```python
from pydantic import BaseModel

class Item(BaseModel):
    id: str
    name: str
```

## app/routers/items.py (routes + schemas; calls functions/)

```python
from fastapi import APIRouter
from pydantic import BaseModel
from ..functions import items as items_fn
from ..models.item import Item

router = APIRouter(prefix="/items", tags=["items"])

class CreateItemRequest(BaseModel):
    name: str

class ItemResponse(BaseModel):
    id: str
    name: str

@router.get("", response_model=list[ItemResponse])
async def list_items():
    return await items_fn.list_items()

@router.post("", response_model=ItemResponse, status_code=201)
async def create_item(body: CreateItemRequest):
    item: Item = await items_fn.create_item(body.name)
    return item
```

## app/main.py (imports + registers routers ONLY)

API key applied per-router so health can be exempted from auth (and optionally
from the API key — see references/api-key.md for the probe tradeoff).

```python
from fastapi import Depends, FastAPI
from .dependencies import require_api_key, get_current_user
from .routers import health, items
# from .routers import auth                # jwt option

app = FastAPI(title="Backend API")

# Health: NO auth. Choose ONE of the following for the API key:
#   (A) require API key here too (probe must send X-API-Key), or
#   (B) leave it off so a Cloud Run probe can reach it.
app.include_router(health.router)                                  # option B

# Auth bootstrap (jwt): API key required, but NOT get_current_user.
# app.include_router(auth.router, dependencies=[Depends(require_api_key)])

# Protected resources: API key + auth on every endpoint.
app.include_router(
    items.router,
    dependencies=[Depends(require_api_key), Depends(get_current_user)],
)
```

Alternative (API key truly global, then health needs a probe header — option A):

```python
app = FastAPI(dependencies=[Depends(require_api_key)])
app.include_router(health.router)                                  # api key only
app.include_router(items.router, dependencies=[Depends(get_current_user)])
```

## .env (gitignored)

```
API_KEY=replace-with-long-random-secret
JWT_SECRET=replace-with-long-random-secret
```

## Run

```bash
uvicorn app.main:app --reload
# health:  curl localhost:8000/health
# items:   curl -H "X-API-Key: ..." -H "Authorization: Bearer ..." localhost:8000/items
```
