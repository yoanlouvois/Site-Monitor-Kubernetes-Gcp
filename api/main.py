import psycopg
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, HttpUrl

from common.db import get_conn

app = FastAPI(title="Site Monitor API")


class SiteIn(BaseModel):
    name: str
    url: HttpUrl  # Pydantic vérifie que c'est une URL valide, sinon erreur 422


@app.get("/health")
def health():
    with get_conn() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.get("/sites")
def list_sites():
    with get_conn() as conn:
        return conn.execute("""
            SELECT s.id, s.name, s.url, s.is_up, s.created_at,
                   ROUND(100.0 * COUNT(c.id) FILTER (WHERE c.is_up)
                         / NULLIF(COUNT(c.id), 0), 2) AS uptime_7d
            FROM sites s
            LEFT JOIN checks c
                   ON c.site_id = s.id
                  AND c.checked_at > now() - interval '7 days'
            GROUP BY s.id
            ORDER BY s.id
        """).fetchall()


@app.post("/sites", status_code=201)
def create_site(site: SiteIn):
    try:
        with get_conn() as conn:
            return conn.execute(
                "INSERT INTO sites (name, url) VALUES (%s, %s) RETURNING *",
                (site.name, str(site.url)),
            ).fetchone()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, "Ce site est déjà surveillé")


@app.put("/sites/{site_id}")
def update_site(site_id: int, site: SiteIn):
    try:
        with get_conn() as conn:
            row = conn.execute(
                "UPDATE sites SET name = %s, url = %s WHERE id = %s RETURNING *",
                (site.name, str(site.url), site_id),
            ).fetchone()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, "Ce site est déjà surveillé")
    if row is None:
        raise HTTPException(404, "Site introuvable")
    return row


@app.delete("/sites/{site_id}", status_code=204)
def delete_site(site_id: int):
    with get_conn() as conn:
        deleted = conn.execute("DELETE FROM sites WHERE id = %s", (site_id,)).rowcount
    if deleted == 0:
        raise HTTPException(404, "Site introuvable")


@app.get("/sites/{site_id}/checks")
def site_checks(site_id: int, limit: int = Query(50, ge=1, le=1000)):
    with get_conn() as conn:
        return conn.execute("""
            SELECT checked_at, is_up, status_code, response_time_ms, error
            FROM checks
            WHERE site_id = %s
            ORDER BY checked_at DESC
            LIMIT %s
        """, (site_id, limit)).fetchall()


@app.get("/sites/{site_id}/uptime")
def site_uptime(site_id: int, days: int = Query(7, ge=1, le=30)):
    with get_conn() as conn:
        stats = conn.execute("""
            SELECT COUNT(*) AS total,
                   COUNT(*) FILTER (WHERE is_up) AS up,
                   ROUND(AVG(response_time_ms) FILTER (WHERE is_up)) AS avg_response_ms
            FROM checks
            WHERE site_id = %s
              AND checked_at > now() - make_interval(days => %s::int)
        """, (site_id, days)).fetchone()

    uptime = round(100 * stats["up"] / stats["total"], 2) if stats["total"] else None
    return {
        "site_id": site_id,
        "days": days,
        "total_checks": stats["total"],
        "uptime_percent": uptime,
        "avg_response_ms": stats["avg_response_ms"],
    }