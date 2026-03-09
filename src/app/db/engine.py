"""
Database engine and session factory helpers.

This template is SQLite-first, so the helpers optimize the default
`sqlite+aiosqlite` path while still allowing explicit non-SQLite
configuration when the caller provides it.
"""

import logging
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from sqlalchemy import event
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ..settings import Settings

logger = logging.getLogger(__name__)


def _ensure_sqlite_parent_exists(database_url: str) -> None:
    """Create the parent directory for the default file-backed SQLite URL."""
    prefix = "sqlite+aiosqlite:///"
    if not database_url.startswith(prefix):
        return

    sqlite_path = database_url.removeprefix(prefix)
    if sqlite_path.startswith(":memory:"):
        return

    path = Path(sqlite_path)
    if not path.is_absolute():
        path = Path.cwd() / path
    path.parent.mkdir(parents=True, exist_ok=True)


def _register_sqlite_pragmas(engine: AsyncEngine, settings: Settings) -> None:
    """Register an event listener that applies production SQLite pragmas on every new connection."""

    @event.listens_for(engine.sync_engine, "connect")
    def _set_sqlite_pragmas(dbapi_connection: Any, _connection_record: Any) -> None:
        cursor = dbapi_connection.cursor()
        cursor.execute(f"PRAGMA journal_mode={settings.database_sqlite_journal_mode}")
        cursor.execute(f"PRAGMA synchronous={settings.database_sqlite_synchronous}")
        cursor.execute(f"PRAGMA busy_timeout={settings.database_sqlite_busy_timeout}")
        cursor.execute(f"PRAGMA cache_size={settings.database_sqlite_cache_size}")
        fk = "ON" if settings.database_sqlite_foreign_keys else "OFF"
        cursor.execute(f"PRAGMA foreign_keys={fk}")
        if settings.database_sqlite_mmap_size > 0:
            cursor.execute(f"PRAGMA mmap_size={settings.database_sqlite_mmap_size}")
        cursor.close()
        logger.debug(
            "SQLite pragmas applied: journal_mode=%s synchronous=%s busy_timeout=%d",
            settings.database_sqlite_journal_mode,
            settings.database_sqlite_synchronous,
            settings.database_sqlite_busy_timeout,
        )

    logger.info("SQLite production pragmas registered on engine")


def create_database_engine(settings: Settings) -> AsyncEngine:
    """Create the application's async engine, optimized for the default SQLite setup."""
    _ensure_sqlite_parent_exists(settings.database_url)

    connect_args: dict[str, int] = {}
    if settings.database_url.startswith("sqlite+aiosqlite://"):
        connect_args["timeout"] = settings.database_connect_timeout_seconds

    engine_kwargs: dict[str, object] = {
        "echo": settings.database_echo,
        "pool_pre_ping": settings.database_pool_pre_ping,
    }
    if connect_args:
        engine_kwargs["connect_args"] = connect_args

    if not settings.database_url.startswith("sqlite+aiosqlite://"):
        engine_kwargs["pool_size"] = settings.database_pool_size
        engine_kwargs["max_overflow"] = settings.database_max_overflow

    engine = create_async_engine(settings.database_url, **engine_kwargs)

    if settings.database_url.startswith("sqlite+aiosqlite://"):
        _register_sqlite_pragmas(engine, settings)

    return engine


def create_session_factory(
    settings: Settings,
    engine: AsyncEngine,
) -> async_sessionmaker[AsyncSession]:
    """Create the async session factory bound to the configured engine."""
    _ = settings
    return async_sessionmaker(
        engine,
        expire_on_commit=False,
        autoflush=False,
        autocommit=False,
    )


async def session_scope(
    session_factory: async_sessionmaker[AsyncSession],
) -> AsyncIterator[AsyncSession]:
    """Yield a request-scoped database session."""
    async with session_factory() as session:
        yield session
