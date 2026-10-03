import psycopg
from psycopg.rows import dict_row

from common import config


def get_conn():
    """Ouvre une connexion à PostgreSQL. Les lignes sont renvoyées sous forme de dictionnaires."""
    return psycopg.connect(
        host=config.POSTGRES_HOST,
        port=config.POSTGRES_PORT,
        user=config.POSTGRES_USER,
        password=config.POSTGRES_PASSWORD,
        dbname=config.POSTGRES_DB,
        row_factory=dict_row,
    )