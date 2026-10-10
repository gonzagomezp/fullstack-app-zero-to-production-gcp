# DB adapters (db/ — omit entirely if db=none)

Pick ONE. Each adapter lives under `app/db/` with a connection/init plus a tiny
repository. Routers never touch the DB directly — `functions/` call repositories.

---

## Firestore (default) — google-cloud-firestore

Install: `google-cloud-firestore`. Auth via Application Default Credentials on
GCP, or a service-account JSON locally.

### app/db/firestore.py

```python
from functools import lru_cache
from google.cloud import firestore

@lru_cache
def get_client() -> firestore.AsyncClient:
    return firestore.AsyncClient()      # project + creds from environment
```

### app/db/users_repo.py (example repository)

```python
from .firestore import get_client
from ..models.user import User

_COLLECTION = "users"

async def get_user_by_id(user_id: str) -> User | None:
    snap = await get_client().collection(_COLLECTION).document(user_id).get()
    return User(id=snap.id, **snap.to_dict()) if snap.exists else None

async def create_user(user: User) -> None:
    await get_client().collection(_COLLECTION).document(user.id).set(
        user.model_dump(exclude={"id"})
    )
```

---

## Postgres by URL — SQLAlchemy async + psycopg 3

Any Postgres reachable through a connection URL: Cloud SQL by IP, Neon, Supabase,
self-hosted. Install: `sqlalchemy[asyncio]` `psycopg[binary]`.

psycopg (not asyncpg) because it is libpq-based: the URL works exactly as the
provider hands it out, `?sslmode=require` included. asyncpg rejects `sslmode`.

### settings (additions)

```python
db_uri: str             # DB_URI — postgres://user:pass@host:5432/db?sslmode=require
```

### app/db/postgres.py

```python
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase
from ..settings import settings

class Base(DeclarativeBase):
    pass

# Providers hand out postgres:// or postgresql://; SQLAlchemy needs the driver in
# the scheme. The query string (sslmode, etc.) passes through to libpq untouched.
_url = make_url(settings.db_uri).set(drivername="postgresql+psycopg")

engine = create_async_engine(_url, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

async def get_session() -> AsyncSession:           # FastAPI dependency
    async with SessionLocal() as session:
        yield session
```

Behind a transaction-mode pooler (Supabase on port 6543, PgBouncer) prepared
statements break: add `connect_args={"prepare_threshold": None}` to the engine.

Models + repositories: same as the Cloud SQL section below (`Base`,
`get_session`, `UserRow`, `users_repo.py`).

Close on shutdown: `await engine.dispose()` in lifespan.

---

## Cloud SQL Postgres — SQLAlchemy 2.x async + asyncpg + Cloud SQL Connector

Through Google's connector (IAM-authorized, no IP allowlist), with instance +
user + password instead of a URL. The connector only supports asyncpg/pg8000 for
Postgres, so this option stays on asyncpg.

Install: `sqlalchemy[asyncio]` `asyncpg` `cloud-sql-python-connector[asyncpg]`.

### settings (additions)

```python
instance_connection_name: str   # "project:region:instance"
db_user: str
db_pass: str
db_name: str
```

### app/db/postgres.py

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import DeclarativeBase
from google.cloud.sql.connector import Connector, IPTypes
from ..settings import settings

class Base(DeclarativeBase):
    pass

_connector = Connector()

async def _getconn():
    return await _connector.connect_async(
        settings.instance_connection_name,
        "asyncpg",
        user=settings.db_user,
        password=settings.db_pass,
        db=settings.db_name,
        ip_type=IPTypes.PRIVATE,        # or PUBLIC
    )

engine = create_async_engine("postgresql+asyncpg://", async_creator=_getconn)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

async def get_session() -> AsyncSession:           # FastAPI dependency
    async with SessionLocal() as session:
        yield session
```

### app/models/user.py (ORM) + repository

```python
# models/user.py
from sqlalchemy.orm import Mapped, mapped_column
from ..db.postgres import Base

class UserRow(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(unique=True, index=True)
    hashed_password: Mapped[str]
    disabled: Mapped[bool] = mapped_column(default=False)
```

```python
# db/users_repo.py
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from ..models.user import UserRow

async def get_user_by_email(session: AsyncSession, email: str) -> UserRow | None:
    res = await session.execute(select(UserRow).where(UserRow.email == email))
    return res.scalar_one_or_none()
```

Close the connector on shutdown: `await _connector.close_async()` in lifespan.

---

## MongoDB by URL — PyMongo Async API

Install: `pymongo`. Not `motor`: deprecated since 2025-05-14 in favour of
PyMongo's native async API, end of life 2026-05-14.

**Production: MongoDB Atlas.** Local/dev can be a Docker `mongo` or an Atlas
dev cluster; only `DB_URI` changes.

### settings (additions)

```python
db_uri: str             # DB_URI — mongodb+srv://user:pass@cluster.xxxxx.mongodb.net/?retryWrites=true&w=majority
mongo_db: str           # MONGO_DB — Atlas URIs usually don't carry the database name
```

### app/db/mongo.py

```python
from functools import lru_cache
from pymongo import AsyncMongoClient
from pymongo.asynchronous.database import AsyncDatabase
from ..settings import settings

@lru_cache
def get_client() -> AsyncMongoClient:
    return AsyncMongoClient(settings.db_uri)

def get_db() -> AsyncDatabase:
    return get_client()[settings.mongo_db]
```

### app/db/users_repo.py

```python
from .mongo import get_db
from ..models.user import User

async def get_user_by_id(user_id: str) -> User | None:
    doc = await get_db().users.find_one({"_id": user_id})
    if not doc:
        return None
    doc["id"] = doc.pop("_id")
    return User(**doc)

async def create_user(user: User) -> None:
    doc = user.model_dump()
    doc["_id"] = doc.pop("id")
    await get_db().users.insert_one(doc)
```

The client connects lazily: in lifespan, `await get_db().command("ping")` on
startup (fails fast on a bad URI) and `await get_client().close()` on shutdown
(`close()` is a coroutine in the async API).

**Atlas network access (decide at deploy, ask the user):** the `api` service
goes out to the internet without VPC egress, so it has no fixed outbound IP.
Atlas' IP Access List then needs either `0.0.0.0/0` (relying on the
user/password in the URI) or a static IP via Cloud NAT. Record the choice in the
decisions log.
