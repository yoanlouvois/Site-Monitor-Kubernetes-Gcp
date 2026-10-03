import redis

from common import config


def get_redis():
    return redis.Redis(host=config.REDIS_HOST, port=config.REDIS_PORT, decode_responses=True)