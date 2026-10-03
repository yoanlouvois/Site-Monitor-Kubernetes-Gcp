import asyncio
import time
from datetime import datetime, timezone

import httpx

from common import config
from common.db import get_conn
from common.redis_client import get_redis

TIMEOUT_SECONDS = 10    # au-delà, le site est considéré en panne
MAX_CONCURRENCY = 20    # nombre maximum de requêtes simultanées


async def check_site(client, semaphore, site):
    """Teste un site et renvoie le résultat. Ne lève jamais d'exception."""
    async with semaphore:
        start = time.perf_counter()
        try:
            response = await client.get(site["url"])
            return {
                "site": site,
                "is_up": response.status_code < 400,
                "status_code": response.status_code,
                "response_time_ms": int((time.perf_counter() - start) * 1000),
                "error": None,
            }
        except httpx.HTTPError as exc:
            # DNS introuvable, timeout, connexion refusée, certificat invalide...
            return {
                "site": site,
                "is_up": False,
                "status_code": None,
                "response_time_ms": None,
                "error": f"{type(exc).__name__}: {exc}"[:500],
            }


async def run_checks(sites):
    semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
    async with httpx.AsyncClient(
        timeout=TIMEOUT_SECONDS,
        follow_redirects=True,
        headers={"User-Agent": "site-monitor/1.0"},
    ) as client:
        return await asyncio.gather(*(check_site(client, semaphore, s) for s in sites))


def main():
    # Lire les sites et leur dernier état connu
    with get_conn() as conn:
        sites = conn.execute("SELECT id, name, url, is_up FROM sites").fetchall()

    if not sites:
        print("Aucun site à vérifier.")
        return

    # Tout tester en parallèle
    results = asyncio.run(run_checks(sites))

    # Enregistrer les résultats et repérer les changements d'état
    changes = []
    with get_conn() as conn:
        for r in results:
            site = r["site"]
            conn.execute(
                """INSERT INTO checks (site_id, is_up, status_code, response_time_ms, error)
                   VALUES (%s, %s, %s, %s, %s)""",
                (site["id"], r["is_up"], r["status_code"], r["response_time_ms"], r["error"]),
            )
            conn.execute("UPDATE sites SET is_up = %s WHERE id = %s", (r["is_up"], site["id"]))

            # Changement d'état = il y avait un état connu, et il est différent
            if site["is_up"] is not None and site["is_up"] != r["is_up"]:
                changes.append(r)

            status = "UP  " if r["is_up"] else "DOWN"
            detail = r["status_code"] or r["error"]
            print(f"[{status}] {site['name']} ({site['url']}) -> {detail}")

    # Publier les changements, seulement après l'enregistrement en base
    redis = get_redis()
    now = datetime.now(timezone.utc).isoformat()
    for r in changes:
        redis.xadd(
            config.EVENTS_STREAM,
            {
                "site_id": r["site"]["id"],
                "name": r["site"]["name"],
                "url": r["site"]["url"],
                "is_up": "1" if r["is_up"] else "0",
                "status_code": r["status_code"] or "",
                "error": r["error"] or "",
                "at": now,
            },
            maxlen=1000,  # le flux garde au plus environ 1000 événements
        )
        print(f"Événement publié : {r['site']['name']} -> {'UP' if r['is_up'] else 'DOWN'}")

    print(f"{len(results)} site(s) vérifié(s), {len(changes)} changement(s) d'état.")


if __name__ == "__main__":
    main()