import os

# En local, charge le fichier .env s'il existe. Dans les conteneurs, python-dotenv
# n'est pas installé : on passe simplement à la suite, et les variables viennent
# de Docker ou de Kubernetes.
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass


def _env(name, default=None):
    value = os.getenv(name, default)
    if value is None:
        raise RuntimeError(f"Variable d'environnement manquante : {name}")
    return value


POSTGRES_HOST = _env("POSTGRES_HOST", "localhost")
POSTGRES_PORT = int(_env("POSTGRES_PORT", "5432"))
POSTGRES_USER = _env("POSTGRES_USER")
POSTGRES_PASSWORD = _env("POSTGRES_PASSWORD")
POSTGRES_DB = _env("POSTGRES_DB")

REDIS_HOST = _env("REDIS_HOST", "localhost")
REDIS_PORT = int(_env("REDIS_PORT", "6379"))

# Nom du flux Redis où le checker publie les changements d'état
EVENTS_STREAM = "site_events"