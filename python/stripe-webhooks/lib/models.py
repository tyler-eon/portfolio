from pydantic import BaseModel


class StripeEventRequest(BaseModel):
    id: str | None = None
    idempotency_key: str | None = None


class StripeEventData(BaseModel):
    object: dict
    previous_attributes: dict | None = None


class StripeEvent(BaseModel):
    id: str
    api_version: str | None = None
    data: StripeEventData
    request: StripeEventRequest | None = None
    type: str
    created: int


class PubSubEvent(BaseModel):
    secret: str
    event: StripeEvent
