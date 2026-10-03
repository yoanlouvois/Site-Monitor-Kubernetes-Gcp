import os
import signal
import socket
import time

import httpx
import redis

from common import config
from common.redis_client import get_redis

GROUP = "alerter"
CONSUMER = socket.gethostname()  # nom unique

WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL")
if not WEBHOOK_URL:
    raise RuntimeError("Variable d'environnement manquante : DISCORD_WEBHOOK_URL")

running = True


def stop(signum, frame):
    """Appelée quand Docker ou Kubernetes demande l'arrêt du programme."""
    global running
    print("Signal d'arrêt reçu, fin de la boucle...")
    running = False


def send_alert(event):
    """Envoie l'alerte sur Discord. Renvoie True si l'événement est traité."""
    if event["is_up"] == "1":
        title = f"🟢 {event['name']} est de nouveau en ligne"
        description = f"{event['url']}\nCode HTTP : {event['status_code']}"
        color = 0x2ECC71  # vert
    else:
        title = f"🔴 {event['name']} est en panne"
        detail = event["error"] or f"Code HTTP : {event['status_code']}"
        description = f"{event['url']}\n{detail}"
        color = 0xE74C3C  # rouge

    payload = {
        "embeds": [{
            "title": title,
            "description": description,
            "color": color,
            "timestamp": event["at"],
        }]
    }

    try:
        response = httpx.post(WEBHOOK_URL, json=payload, timeout=10)
    except httpx.HTTPError as exc:
        print(f"Échec de l'envoi, nouvel essai plus tard : {exc}")
        return False

    if response.status_code == 429:
        # Trop de messages : Discord indique combien de secondes attendre
        wait = response.json().get("retry_after", 5)
        print(f"Limite de Discord atteinte, attente de {wait} s")
        time.sleep(wait)
        return False
    if response.status_code >= 500:
        print(f"Discord indisponible ({response.status_code}), nouvel essai plus tard")
        return False
    if response.status_code >= 400:
        # Erreur de notre côté (message invalide, webhook supprimé...) :
        # réessayer ne changerait rien, on abandonne ce message.
        print(f"Discord a refusé le message ({response.status_code}) : {response.text}")
        return True
    return True


def ensure_group(r):
    """Crée le groupe de consommateurs s'il n'existe pas encore."""
    try:
        r.xgroup_create(config.EVENTS_STREAM, GROUP, id="0", mkstream=True)
        print(f"Groupe '{GROUP}' créé.")
    except redis.ResponseError as exc:
        if "BUSYGROUP" not in str(exc):  # BUSYGROUP = le groupe existe déjà, c'est normal
            raise


def main():
    signal.signal(signal.SIGTERM, stop)  # envoyé par Docker et Kubernetes à l'arrêt
    signal.signal(signal.SIGINT, stop)   # Ctrl+C en local

    r = get_redis(socket_timeout=15)  # doit rester supérieur à block (5 s)
    ensure_group(r)
    print(f"Alerter démarré (consommateur : {CONSUMER})")

    # "0" : d'abord les messages déjà reçus mais pas encore acquittés
    # ">" : ensuite, uniquement les nouveaux messages
    read_from = "0"

    while running:
        try:
            response = r.xreadgroup(
                GROUP, CONSUMER, {config.EVENTS_STREAM: read_from}, count=10, block=5000
            )
        except (redis.ConnectionError, redis.TimeoutError) as exc:
            print(f"Redis injoignable, nouvel essai dans 5 s : {exc}")
            time.sleep(5)
            continue

        messages = response[0][1] if response else []

        if not messages:
            read_from = ">"  # plus rien en attente
            continue

        for message_id, event in messages:
            if send_alert(event):
                r.xack(config.EVENTS_STREAM, GROUP, message_id)
                state = "UP" if event["is_up"] == "1" else "DOWN"
                print(f"Alerte envoyée : {event['name']} -> {state}")
            else:
                read_from = "0"  # échec
                time.sleep(5)
                break

    print("Alerter arrêté proprement.")


if __name__ == "__main__":
    main()