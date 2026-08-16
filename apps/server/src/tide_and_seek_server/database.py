from __future__ import annotations

from collections.abc import Iterator

from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .models import Base


def create_database_engine(settings: Settings) -> Engine:
    connect_args = (
        {"check_same_thread": False}
        if settings.database_url.startswith("sqlite")
        else {"connect_timeout": 5}
    )
    engine = create_engine(
        settings.database_url,
        pool_pre_ping=True,
        connect_args=connect_args,
    )
    if settings.database_url.startswith("sqlite"):

        @event.listens_for(engine, "connect")
        def enable_sqlite_foreign_keys(dbapi_connection, _connection_record) -> None:
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    return engine


def create_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, expire_on_commit=False)


def initialize_schema(engine: Engine) -> None:
    Base.metadata.create_all(engine)


def session_dependency(factory: sessionmaker[Session]) -> Iterator[Session]:
    with factory() as session:
        yield session
