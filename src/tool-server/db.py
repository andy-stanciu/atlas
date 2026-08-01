from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from config import DATABASE_PATH


class Base(DeclarativeBase):
    pass


DATABASE_PATH.parent.mkdir(parents=True, exist_ok=True)
engine = create_engine(
    f"sqlite+pysqlite:///{DATABASE_PATH}",
    connect_args={"check_same_thread": False, "timeout": 5},
)
Session = sessionmaker(bind=engine, expire_on_commit=False)


@event.listens_for(engine, "connect")
def configure_sqlite(connection, _):
    cursor = connection.cursor()
    cursor.execute("PRAGMA foreign_keys = ON")
    cursor.execute("PRAGMA journal_mode = WAL")
    cursor.close()
