# Credits

Manages service credits for users.

## User Credits

Each user can have one of three types of credit (called a *bucket*): `trial`, `permanent`, and `expiring`.

Trial credits are semi-permanent credits; they exist indefinitely but are intended to only be used while in a trial state.

Permanent credits are exactly that: service credits which persist forever until used or otherwise manually removed.

Expiring credits are also as they sound: service credits that will expire after a set amount of time. Each of these credits tracks its own initial value and expiration date, meaning it is possible to have a set of expiring credits where parts of the sum each expire at different times.

These credits are represented by two data schema: `UserCredits` and `ExpiringCredit`. However, as the original data structure for this construct was codified in NoSQL (specifically MongoDB), expiring credits are an embedded data structure within the user credits. In a fully relational world, these would be two separate tables. This would be beneficial because tracking expiring credits in a separate table allows us to more easily do things like add a property of `expired` so that we can index `expired = false` and retain a full list of expiring credits, even those that are expired, for at least some amount of time past its expiration date.

Speaking of tracking expired credits...

## Credit Change Tracking

Although not present in this example project, the original code included an additional table specifically for tracking credit changes. Every time credits were added or removed, a credit change event was published to NATS. A separate service watched for these credit change events and added the details to this separate change tracking table.

However, I eventually made the change tracking commit synchronous, i.e. I did it right before I tried to change a user's credits. Why? Because the change tracking table held uniquely-identifying information regarding the source of a change event. This meant that the change tracking table could be used to ensure idempotency in our at-least-once message delivery design. If the same message did get replayed, and we could see that the composite primary key already existed in the change tracking table, we would simply acknowledge the message and ignore it.

This ended up also allowing us to implement a function where you could poll for whether a particular event that invoked a change had completed yet. By supplying the same uniquely-identifying pieces of data, it was trivial to see whether e.g. a purchase for more service credits had been applied to a user's account yet.

And it also allowed us to audit against closed invoices, to ensure that if we had events which didn't end up in the message queue appropriately that we could retroactively find those paid invoices and either refund them or honor the purchase by applying the service credits late.

## Event-Driven Design

This application is purely reactive. It uses the Broadway library to receive incoming messages from a durable message queue and pass them along to a set of processors. In this project, I had initially used NATS because it seemed to check all of the boxes better than the two alternatives, Kafka and CLoud Pub/Sub.

Kafka does not have a simple way, that I could determine at the time, to ensure at-least-once message delivery. My understanding is that individual messages for a given topic are not tracked for acknowledgement, rather it is the most recent message acknowledged that is tracked. Each broker on each partition tracks, per consumer group (and universally for consumers not using a unique group id), the most recently-acknowledged message in the event log. So if you happen to acknowledge message B but didn't actually manage to successfully process message A, it's possible you might not see message A again.

I'm sure there are ways around this, like by ensuring you just process one message at a time per broker per partition, but I didn't want to constrain myself to that limitation. And I wasn't aware of any other simple alternatives to the problem at the time.

Cloud Pub/Sub was only passed on because I started off wanting a push-based consumer flow, and Cloud Pub/Sub required a domain name for the push endpoint. I was running the service inside Kubernetes and only had an internal IP address readily-available, so it was legitimate easier to use the NATS Kubernetes Helm chart to set up a NATS server with almost no effort. And they also had a Kubernetes Operator that allowed me to codify the core NATS resources I needed (streams and consumers) using standard Kubernetes manifests, which was another awesome win.

Ultimately, pull-based consumer flows are always "better" in the sense that they are more flexible and allow you to fine-tune behavior in ways that push-based consumer flows simply can't. And push-based consumer flows in NATS are ridiculously less friendly than with any other message queue solution I've used to date. The documentation doesn't highlight any of the short-comings inherent in their implementation of push-based consumers which can lead to major problems down-the-road that you just can't easily anticipate.

And if I was going to end up going with a pull-based consumer flow anyway, Cloud Pub/Sub would have been perfectly acceptable as an alternative to Kafka. Other systems were already using it and the Kubernetes cluster was running on GKE anyway, so everything was already in GCP.

## How It Worked

We had effectively two primary event flows:

1. Purchasing service credits either individually or as part of a recurring subscription.
2. Spending service credits by completing "jobs".

When service credits needed to be granted (#1) we used *entitlements* to communicate who was getting how much time to which buckets. We had products which themselves had one or more entitlements each. Whenever a product was purchased, or a recurring subscription created from a product renewed, we received an event from our payment processor. We used the product to fetch the entitlements and then sent those to a Cloud Pub/Sub topic which got funneled into NATS.

When service credits needed to be deducted (#2) we used *job completions* to communicate who to charge and how much. Even before this project existed we already were publishing such events over Kafka, so it was an easy win to just create a consumer group that funneled that data into NATS.

We had a Broadway pipeline which watched a single NATS subject (the consumer's push subject) and then distributed that among a number of processors for concurrent handling. Depending on the exact event type we would calculate the amount of credits to either grant or deduct.

Although not present in this obfuscated version of the project, a check against the uniquely-identifying data present in each event would first be used to determine whether the event was already processed. Since our event pipeline uses an at-least-once delivery guarantee, we needed to protect against processing the same event multiple times. An added benefit to this was that we could sometimes avoid making a network call via `erpc` if we knew that the user process didn't need to do any work because it was already done, so handling that predicate in the message processor proved to be more performant overall.

Also not present here, adding things to the change tracking table and also emitting credit change events.
