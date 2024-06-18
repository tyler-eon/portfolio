from os import environ

import stripe


class Stripe:
    def __init__(self):
        self.client = stripe
        self.client.api_key = environ["STRIPE_API_KEY"]
        self.whsec = environ["STRIPE_WEBHOOK_SECRET"]

    # Returns a Class of Stripe object matching a given type name, e.g. `Customer` or `Invoice`.
    def gettype(self, type: str):
        return getattr(self.client, type)

    # Returns true if the given signature is valid for the given payload. Returns false otherwise.
    #
    # *Important*: Events that fail signature verification should be ignored, as they are not guaranteed to be from Stripe.
    def verify_signature(self, signature: str, payload: str, /):
        try:
            self.client.WebhookSignature.verify_header(
                payload, signature, self.whsec, self.client.Webhook.DEFAULT_TOLERANCE
            )
        except ValueError:
            return False
        return True
