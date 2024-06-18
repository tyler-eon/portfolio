import importlib
from contextlib import asynccontextmanager
from os import environ

from databases import Database
from fastapi import FastAPI, HTTPException, Request, Response
from stripe import RateLimitError, StripeError

from context import Context
from lib.logging import setup_logging
from lib.models import PubSubEvent, StripeEvent
from lib.publisher import Publisher
from lib.stripe import Stripe


# Prefer DATABASE_URI, but fall back to individual component env vars if necessary.
db_uri = environ.get("DATABASE_URI")
if db_uri is None:
    db_user = environ.get("DATABASE_USER", "postgres")
    db_pass = environ.get("DATABASE_PASSWORD", "postgres")
    db_host = environ.get("DATABASE_HOST", "postgres")
    db_port = environ.get("DATABASE_PORT", "5432")
    db_name = environ.get("DATABASE_NAME", "postgres")
    db_uri = f"postgresql+asyncpg://{db_user}:{db_pass}@{db_host}:{db_port}/{db_name}"

database = Database(db_uri)
client = Stripe()
publisher = Publisher()


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    await database.connect()
    yield
    await database.disconnect()


app = FastAPI(lifespan=lifespan)


@app.post("/receive")
async def webhook(event: StripeEvent, request: Request):
    # Verify the event request signature first.
    signature = request.headers.get("Stripe-Signature", "")
    payload = (await request.body()).decode("utf-8")
    if not client.verify_signature(signature, payload):
        return Response(status_code=401)

    # If we don't have a publisher, process the event synchronously.
    if not publisher.is_connected or not publisher.default_topic:
        return await process_event(event)

    # Otherwise, queue the event via the publisher for asynchronous processing.
    payload = {"secret": environ.get("PUBSUB_SECRET"), "event": event.model_dump()}
    await publisher.publish(payload)


@app.post("/pubsub")
async def pubsub(pubsub_event: PubSubEvent):
    # Verify the event secret first.
    if pubsub_event.secret != environ.get("PUBSUB_SECRET"):
        # We ACK the event even if it's not valid, to prevent it from re-sending.
        return Response(status_code=204)

    # Process the embedded Stripe event.
    return await process_event(pubsub_event.event)


async def process_event(event: StripeEvent):
    # Create an event context to pass to the handler.
    ctx = Context(database=database, stripe=client, event=event)
    fun = None

    # All event types are dot-deliminted module paths + function names.
    # e.g. event type `customer.subscription.created` maps to:
    #   - File `events/customer/subscription.py`
    #   - Module `events.customer.subscription`
    #   - Function `created`
    # So we import `events.customer.subscription` from `events/customer/subscription.py` and then call `created(ctx)` on the module.
    # It is assumed that all imported functions are async and will be awaited when called.
    parts = event.type.split(".")
    fname = parts.pop()

    try:
        # Because some "packages" might be named the same as some "modules"...
        # We use `spec_from_file_location` and `module_from_spec` to load the module from a known file path pattern.
        spec = importlib.util.spec_from_file_location(  # pyright: ignore[reportAttributeAccessIssue]
            f"events.{'.'.join(parts)}", f"events/{'/'.join(parts)}.py"
        )
        module = importlib.util.module_from_spec(  # pyright: ignore[reportAttributeAccessIssue]
            spec
        )

        # Will throw a `FileNotFoundError` if we just don't have a file/module for this event object.
        spec.loader.exec_module(module)

        # Will throw an `AttributeError` if we don't have a function for this event type.
        fun = getattr(module, fname)
    # Notice that we only log the event if we don't have a handler for it. This is intentional.
    # We want to ACK the event even if we don't have a handler for it yet, to prevent it from re-sending.
    except FileNotFoundError:
        ctx.warning(f"No event module for {event.type}", {"event_id": event.id})
        return {"success": True}
    except AttributeError:
        ctx.warning(f"No event handler for {event.type}", {"event_id": event.id})
        return {"success": True}
    # If we get a Stripe 429, it means we're being rate-limited. We should retry the event later.
    except RateLimitError as e:
        ctx.warning(f"Rate-limited by Stripe", {"event_id": event.id, "error": str(e)})
        raise HTTPException(status_code=429, detail="Rate-limited by Stripe")
    except StripeError as e:
        if e.http_status == 429:
            ctx.warning(
                f"Rate-limited by Stripe", {"event_id": event.id, "error": str(e)}
            )
            raise HTTPException(status_code=429, detail="Rate-limited by Stripe")

    assert fun is not None

    # Check if we can increment our webhook tracker. If false, we've already processed a more recent occurence of this event.
    if not (await ctx.check_webhook_tracker()):
        return {"success": True}

    # The event requires processing, so let's call the handler.
    # If any exceptions are raised at this point, that will ensure Stripe retries the event later.
    await fun(ctx)

    # Now we actually write the updated timestamp to the webhook tracker table.
    await ctx.increment_webhook_tracker()
    return {"success": True}
