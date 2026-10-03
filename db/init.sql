CREATE TABLE sites (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    url         TEXT NOT NULL UNIQUE,
    is_up       BOOLEAN,              -- dernier état connu (NULL = jamais testé)
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE checks (
    id                BIGSERIAL PRIMARY KEY,
    site_id           INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    checked_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_up             BOOLEAN NOT NULL,
    status_code       INTEGER,        -- NULL si le site n'a pas répondu
    response_time_ms  INTEGER,
    error             TEXT
);

CREATE INDEX idx_checks_site_time ON checks (site_id, checked_at DESC);