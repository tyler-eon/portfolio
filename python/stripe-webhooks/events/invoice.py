from typing import Any, Dict, Optional

from stripe import Customer, Invoice

from context import Context


# invoice.paid
async def paid(ctx: Context) -> None:
    invoice: Invoice = Invoice.retrieve(ctx.resource["id"], expand=["customer"])

    # Only process invoices for non-subscription events (i.e. one-off purchases).
    # Subscription events should be handled via `customer.subscription.*` events.
    if invoice.subscription is None:
        assert isinstance(invoice.customer, Customer)
        user_id = ctx.get_user_id(invoice.customer)
        if user_id is None:
            ctx.warning(
                f"Unable to find user id for customer. Skipping.",
                {"customer_id": invoice.customer.id},
            )
            return
        await push_entitlements_from_line_items(ctx, user_id, invoice)


async def push_entitlements_from_line_items(
    ctx: Context, user_id: str, invoice: Invoice
) -> Optional[list[Dict[str, Any]]]:
    line_items = invoice.lines.data
    price_ids = [li.price.id for li in line_items if li.price]

    if not price_ids:
        ctx.warning(
            f"No price IDs found for Invoice {invoice.id}. No entitlements data to process."
        )
        return None

    ctx.info(
        "Pushing entitlements for user.", {"user_id": user_id, "price_ids": price_ids}
    )

    # We would have some logic here to fetch entitlement data from the Stripe price ids via `ctx.database`.
    # Then, if we successfully fetched one or more entitlements, we would throw that into an entitlements event payload.
    # That payload would then be sent over Cloud Pub/Sub for further processing.

