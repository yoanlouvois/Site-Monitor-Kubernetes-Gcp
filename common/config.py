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


# Postgres : lu seulement quand un service y accède (config.POSTGRES_PASSWORD...).
# Un service qui n'utilise pas la base (l'alerter) n'a donc pas besoin du mot de passe :
# moindre privilège, il ne le reçoit plus du tout.
_POSTGRES_DEFAULTS = {
    "POSTGRES_HOST": "localhost",
    "POSTGRES_PORT": "5432",
    "POSTGRES_USER": None,
    "POSTGRES_PASSWORD": None,
    "POSTGRES_DB": None,
}


def __getattr__(name):
    # Appelé par Python uniquement pour les noms absents du module (PEP 562)
    if name in _POSTGRES_DEFAULTS:
        value = _env(name, _POSTGRES_DEFAULTS[name])
        return int(value) if name == "POSTGRES_PORT" else value
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


REDIS_HOST = _env("REDIS_HOST", "localhost")
REDIS_PORT = int(_env("REDIS_PORT", "6379"))

# Nom du flux Redis où le checker publie les changements d'état
EVENTS_STREAM = "site_events"