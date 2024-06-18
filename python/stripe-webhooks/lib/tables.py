from databases.interfaces import Record
from sqlalchemy import Column, Integer, MetaData, String, Table


__all__ = (
    "_WebhookTracker",
    "WebhookTrackers",
)


class _WebhookTracker(Record):
    """This class should ONLY be used for typing purposes."""

    id: int
    event_id: str
    event_type: str
    updated: int


WebhookTrackers: Table = Table(
    "webhook_trackers",
    MetaData(),
    Column("id", Integer, primary_key=True),
    Column("event_id", String),
    Column("event_type", String),
    Column("updated", Integer),
)
