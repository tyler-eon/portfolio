# Stripe Webhooks

This project was intended to allow developers to easily add in new handlers for Stripe Webhook events as well as quickly forward those events to a second message queue for additional processing.

## Why a Second Message Queue?

Stripe will wait *at least* an hour before trying a failed webhook again. But Stripe also has *sloooooow* API response times, meaning it isn't unusual for an API request to take multiple seconds if a modification to a resource has caused a cascade of changes to occur. And in situations where you attempt to update a resource already in the middle of an update, you'll get an error. And that error will cause the triggered event to wait an hour before it tries again.

TL;DR: Any slowness or errors that occur in the Stripe webhook receiver could cause the event to wait an hour before it is sent again.

This is obviously an awful customer experience, since Stripe events primarily tell us when we've received money and need to fulfill entitlements for a customer. To get around this, we need our own message queue that we can configure with really short retry policies. Since this was originally deployed to Google Cloud Platform, we used Cloud Pub/Sub.

The overall flow is:

1. Receive webhook event from Stripe.
2. Validate signature to ensure the event is legitimately from Stripe.
3. Shove the event into Cloud Pub/Sub.
4. Since the code runs exposed to the internet we need another validation to ensure the Cloud Pub/Sub event is legitimate.
5. Execute the appropriate event handler.

## Event Handlers

To avoid processing Stripe events out of chronological order, we first use a "webhook tracker" record in the database to determine whether a more recent version of this event has taken place for the target resource (e.g. a customer resource). If the event we received is newer, we can process it. There are other strategies we could use to ensure events are processed idempotently, but this was a generic and effective solution.

"Processing", in this context, means dynamically loading the correct module and invoking the appropriate function. By enforcing developers to use a standardized naming schema, we ensure that anyone can just drop in some new code with the appropriate file and function names and start handling new webhook events without having to touch any other part of the project.

Stripe webhook event names are dot-delimited strings. We use this standard for event names to map to filepaths and a function name. The last part of the event name is converted to a function name and all preceeding parts of the event name are concatenated into a file path. For example: `customer.subscription.updated` maps to file `events/customer/subscription.py` and function `updated`.

All functions are assumed to be `async` and have the same input and output specification.

## Developer Velocity

A new hire was able to add an entirely new event handler in less than a week after seeing this project for the first time, with most of that time being spent reading and understanding the Stripe API documentation. As soon as they understood the file and function schema they needed to use, they could quickly implement a new event handler. It probably took more time to write an appropriate set of tests than it did to add the new event handler.

Someone experienced with Stripe was able to add a new handler in less than two days, with about a day of that time being spent creating appropriate test cases since writing tests for Stripe events is rather complicated.
