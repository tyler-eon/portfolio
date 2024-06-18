import logging
from json import dumps
from os import environ
from typing import Optional

from google.auth.exceptions import DefaultCredentialsError
from google.cloud.pubsub_v1 import PublisherClient

from lib.utils import MISSING

logger = logging.getLogger(__name__)


class Publisher:
    # Attempt to create a Pub/Sub publisher client. Requires Google Application Default Credentials to be available.
    def __init__(self):
        try:
            self.default_topic = environ.get("PUBSUB_TOPIC")
            self.client = PublisherClient()
        except DefaultCredentialsError:
            logger.error(
                "Failed to create Pub/Sub publisher client - ensure GOOGLE_APPLICATION_CREDENTIALS is set"
            )
            self.client = MISSING

    # Returns true if the Pub/Sub client is operational.
    @property
    def is_connected(self):
        return self.client is not MISSING

    # Publishes a payload to the given topic and returns the result object.
    #
    # This function will convert the object into a JSON string and encode it into a list of bytes using utf-8 encoding.
    #
    # This function returns after the publish operation has completed.
    async def publish(self, payload: dict, topic: Optional[str] = None):
        future = self.client.publish(
            topic or self.default_topic,  # pyright: ignore [reportArgumentType]
            dumps(payload).encode("utf-8"),
        )
        return future.result()
