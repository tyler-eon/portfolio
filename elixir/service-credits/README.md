# Credits

Manages service credits for users.

Imagine you have a system where interactions with your service (e.g. an AI tool) require "credits" per interaction, and different interactions might have different costs depending on how much resource consumption the underlying task requires. This is a service that manages those credits, allowing different "buckets" of credits to be debited or credited in a way where you don't have race conditions or other major concurrency issues thanks to how Elixir (and Horde, in this particular case) works.

## User Credits

Each user can have one of three types of credit (called a *bucket*): `trial`, `permanent`, and `expiring`.

Trial credits are semi-permanent credits; they exist indefinitely but are intended to only be used while in a trial state.

Permanent credits are exactly that: service credits which persist forever until used or otherwise manually removed.

Expiring credits are also as they sound: service credits that will expire after a set amount of time. Each of these credits tracks its own initial value and expiration date, meaning it is possible to have a set of expiring credits where parts of the sum each expire at different times.

These credits are represented by two data schema: `UserCredits` and `ExpiringCredit`. However, as the original data structure for this construct was codified in NoSQL (specifically MongoDB), expiring credits are an embedded data structure within the user credits. In a fully relational world, these would be two separate tables. This would be beneficial because tracking expiring credits in a separate table allows us to more easily do things like add a property of `expired` so that we can index `expired = false` and retain a full list of expiring credits, even those that are expired, for at least some amount of time past its expiration date.

Speaking of tracking expired credits...

## Credit Change Tracking

Although not present in this example project, the original code included an additional table specifically for tracking credit changes. Every time credits were added or removed, a credit change event was published to a message queue. A separate service watched for these credit change events and added the details to this separate change tracking table.

However, I eventually made the change tracking commit synchronous, i.e. I did it right before I tried to change a user's credits. Why? Because the change tracking table held uniquely-identifying information regarding the source of a change event. This meant that the change tracking table could be used to ensure idempotency in our at-least-once message delivery design. If the same message did get replayed, and we could see that the composite primary key already existed in the change tracking table, we would simply acknowledge the message and ignore it.

This ended up also allowing us to implement a function where you could poll for whether a particular event that invoked a change had completed yet. By supplying the same uniquely-identifying pieces of data, it was trivial to see whether e.g. a purchase for more service credits had been applied to a user's account yet.

And it also allowed us to audit against closed invoices, to ensure that if we had events which didn't end up in the message queue appropriately that we could retroactively find those paid invoices and either refund them or honor the purchase by applying the service credits late.

## Event-Driven Design

This application is purely reactive. It uses the Broadway library to receive incoming messages from a durable message queue and pass them along to a set of processors. In this particular example it would be:

```
Service Provider -> Credit-related Event (via Kafka) -> Credits Service (via Broadway)
```

The two most common event flows were:

1. Purchasing service credits, either individually or as part of a recurring subscription.
2. Spending service credits by completing service "interactions".

When service credits needed to be granted (#1) we used *entitlements* to communicate who was getting how much time to which buckets. Because we used a third-party system to collect payment from users, the actual flow was more complex. In this case we used Stripe and I will talk more about how that factored into the final design below.

When service credits needed to be deducted (#2) we used *events* emitted by the service to communicate who to charge and what parameters should be used to calculate the cost.

## Stripe Webhooks

Stripe uses webhooks to deliver payment events asynchronously. Some payment flows require an asynchronous design or they don't work, e.g. 3DS payments are effectively two-factor auth for payments; that means you could be waiting a long time for someone to (a) see the 3DS challenge and (b) complete it.

However, Stripe did not support configurable retries for failed webhooks. This meant that if a webhook failed to process for some reason, it would take *at least* an hour before the next delivery attempt was made. That's an hour where a user didn't get something they paid for, and that's assuming they aren't unfortunate to encounter an error again.

Therefore, we needed another message queue to temporarily store incoming Stripe webhooks that had configurable retry behavior. Since this solution was originally designed for Google Cloud Platform, we just used a Cloud Run service to accept the incoming webhooks, validated the Stripe signature, and then published the event to a Cloud Pub/Sub topic for further processing. A separate service would ingest those webhook events, typically convert them into entitlements, and then publish that to the internal message queue for the credits service to consume.

Despite having effectively three different services involved (the Stripe webhooks subscriber, the Cloud Pub/Sub subscriber, and the credits service) and two message queues (Cloud Pub/Sub and Kafka), the average latency was ~300ms from start to finish. This does not include the time it takes for Stripe to send the webhook, i.e. the latency between an event and when Stripe sent the webhook. But it does include the time to validate signatures from both Stripe and Cloud Pub/Sub, make 2 to 4 database reads, and make 2 database writes. Each service, even those making database queries, typically had individual latencies of less than 80ms.

## Resource Consumption

Because we stored user credits temporarily in memory, via an Erlang process, there was a high amount of memory consumption. But most modern hardware makes memory relatively cheap, and a faster and more precise pipeline was preferred over memory cost savings.

We typically ran 10+ pods of the Elixir service within Kubernetes, with each pod using upwards of 1.5 CPU on initial startup during high load times but with an average consumption of 0.2 CPU after the first 5 minutes or so. This was due primarily because of (a) copying messages between pods using `erpc` and (b) re-balancing the hash ring which caused processes to be moved between pods.

Memory consumption sat around 500-800 MB per pod during low load times and upwards of 6 GB on "hot" pods during high load times with a median consumption of around 2.5 GB during high load times. In this instance, a "hot" pod refers to having a higher-than-typical rate of event processing, typically associated with a "power user". These users might have 10x or more the number of events as a typical user.

Although this wasn't tested at the time, it is possible that we could have achieved even lower memory consumption by reducing the process inactivity timeout. Although we used a 1-hour timeout, this was specifically one hour of _inactivity_. Every entitlement would reset this timer, so we could have probably looked at our metrics to determine a more appropriate timeout for most users, which would have released processes sooner and likely resulted in lower average memory consumption. But, again, memory is quite cheap (relatively speaking), and therefore there was no motivation to pursue savings in this area.

## Separate Queues

Another design upgrade was to separate entitlements into two "queues": one for debits and one for credits. It was far more likely to debit users as a result of service interactions with far less frequent/more sporadic credit entitlements. But processing a service credit quickly after a purchase is far more critical than debiting from a service interaction quickly.

By separating the queues, we could ensure that we were processing credits would not be effected by a potential "clog" of debit events. This is especially true of power users, or users that happened to be placed on a hot pod, where trying to process messages sequentially could cause credit processing to be unintentionally delayed by a large number of debit events. But if we had separate subscriber pools looking at credit and debit events, we were able to process credit events much faster and without any dependence on the processing of debit events.
