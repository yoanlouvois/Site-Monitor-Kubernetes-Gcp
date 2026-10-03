import redis

from common import config


def get_redis(**options):
    return redis.Redis(
        host=config.REDIS_HOST,
        port=config.REDIS_PORT,
        decode_responses=True,
        protocol=2,  # format de réponse classique, celui qu'attend notre code
        **options,
    )