import logging
from os import environ
from typing import Any, TypeAlias
from uuid import uuid4

import asyncpg
from databases import Database
from pymongo import MongoClient
from stripe import Customer, StripeObject, Subscription

from lib.models import StripeEvent
from lib.stripe import Stripe
from lib.tables import _WebhookTracker, WebhookTrackers


# Type union defines a Customer OR Subscription, which we use frequently for accessing and setting user-related metadata.
CustomerOrSubscription: TypeAlias = Customer | Subscription

logger = logging.getLogger(__name__)


# A class that contains contextual resources for the application.
class Context:
    def __init__(
        self, database: Database, stripe: Stripe, event: StripeEvent
    ):
        self.event = event
        self.stripe = stripe
        self.db = database
        self.mongo = MongoClient(environ.get("MONGO_URI", "mongodb://mongo:27017"))

    @property
    def logger(self):
        return logger

    def prepare_log_extras(self, extra: dict[str, Any] | None, /):
        extra = extra or {}
        extra["event_id"] = self.event.id
        extra["resource_id"] = self.resource["id"]
        return extra

    def debug(self, msg: Any, extra: dict[str, Any] | None = None):
        logger.info(msg, extra=self.prepare_log_extras(extra))

    def info(self, msg: Any, extra: dict[str, Any] | None = None):
        logger.info(msg, extra=self.prepare_log_extras(extra))

    def warning(self, msg: Any, extra: dict[str, Any] | None = None):
        logger.info(msg, extra=self.prepare_log_extras(extra))

    def error(self, msg: Any, extra: dict[str, Any] | None = None):
        logger.info(msg, extra=self.prepare_log_extras(extra))

    # Fetch the database connection.
    @property
    def database(self) -> Database:
        return self.db

    # Fetches the webhook tracker data for the current event, if any prior tracker info exists.
    async def fetch_webhook_tracker(self) -> _WebhookTracker | None:
        evt_id = self.event.data.object["id"]
        evt_type = self.event.type

        tracker = await self.db.fetch_one(
            query="SELECT * FROM webhook_trackers WHERE event_id = :event_id AND event_type = :event_type",
            values={"event_id": evt_id, "event_type": evt_type},
        )

        return tracker  # pyright: ignore [reportReturnType]  # databases is stupid and can't type this properly

    # Returns true if the event for this context is newer than the previous most recent event of the same type.
    async def check_webhook_tracker(self) -> bool:
        t = await self.fetch_webhook_tracker()
        if t is None:
            return True
        return t.updated < self.event.created

    # Attempts to increment our webhook tracker. Returns the updated tracker info.
    async def increment_webhook_tracker(self) -> None:
        evt_id = self.event.data.object["id"]
        evt_type = self.event.type

        created = self.event.created
        t = await self.fetch_webhook_tracker()

        if t is None:
            # Tracker doesn't exist, create a new tracker.
            try:
                values = {
                    "id": uuid4(),
                    "event_id": evt_id,
                    "event_type": evt_type,
                    "updated": created,
                }
                await self.db.execute(
                    query=WebhookTrackers.insert(),
                    values=values,
                )
            except asyncpg.exceptions.UniqueViolationError:
                self.error(
                    "Failed to record webhook tracker event.",
                    {"event_type": evt_type},
                )
                raise RuntimeError("Failed to record webhook tracker event.")
        else:
            # Tracker does exist, update.
            await self.db.execute(
                query=WebhookTrackers.update().where(WebhookTrackers.c.id == t.id),
                values={"updated": created},
            )
            t.updated = created

    # Get the resource associated with the event.
    @property
    def resource(self) -> StripeObject:
        return StripeObject.construct_from(
            values=self.event.data.object, key=self.stripe.client.api_key
        )

    # Helper function to access the "previous attributes" mapping for the event data.
    @property
    def previous_attributes(self) -> dict[str, Any]:
        return self.event.data.previous_attributes or {}

    # Fetches a user id from a Customer or Subscription resource assuming it has a `metadata` property containing `user_id`.
    def get_user_id(self, obj: CustomerOrSubscription) -> str | None:
        # If we can't fetch the `metadata` property, something is wrong, but we'll have to "ignore" it.
        if "metadata" not in obj:
            self.error(
                f"Object {obj.id} has no metadata property, unable to fetch user"
            )
            return None

        # Try to get a valid user id from the object's metadata.
        user_id = obj["metadata"].get("user_id")

        # If we already have a `user_id` metadata property, just return it.
        if user_id is not None:
            return user_id

        # No `user_id`, not ideal.
        self.warning(
            f"Object {obj.id} has no user_id metadata"
        )

        return None
