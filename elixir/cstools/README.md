# Inneal - CS Tools

As with the other projects in my portfolio, please do not expect this to run. Because this particular project was specifically intended to be used internally to assist customer support members, most of the non-Phoenix-generated code had to be removed. Almost everything left deals with basic Stripe functionality, our Ory Keto permissions system integration, or how we used Guardian to perform the authorization flows within the web application. And only the parts which wouldn't give away sensitive data schemas have been kept, so it's been dumbed down a lot for security purposes.

### *Inneal*

Scottish Gaelic - noun - apparatus, gadget, tool

## What is this?

Officially known as *CS Tools*, this is a web-based application intended to provide simple tools to empower customer support agents to assist customers faster and more effectively.

It uses Elixir, Phoenix Framework, and "live views" which allow us to dynamically update parts of the client DOM as assigned data is changed server-side. It's basically just a WebSocket connection to the backend which sends back a map of changed HTML fragments and then local JS code performs dynamic editing of the client DOM to replace the bits that have changed.

## Authorizations

Technically anyone can *attempt* to authenticate via Google Cloud Identity Platform (GCIP), but the application uses a deny-by-default approach so that only those with explicitly-granted authorization can access the system. Even then, different parts of the system are protected by a different set of parameters.

The system being used is based on [Google's Zanzibar](https://research.google/pubs/pub48190/), their consistent, global authorization system. The idea is you have:

1. Namespaces
2. Objects
3. Relations
4. Either a *subject* id or a *subject set* reference

How this works is rather simple: the namespace, object identifier, and relation create a unique key for a single permission. One or more subjects are referenced by this unique key. When asking "does X have permission to Y", the system will construct that unique key for the permission being checked and then determine whether subject *X* is in the set stored under that key. This allows for very fast permission checks but it does mean there's slightly more overhead to maintaining the relationships than in a traditional RBAC system. We don't *need* that lightning fast checking, but if this were to be used in a production system with actual users being validated against these checks, it would be vital to have as low latency as possible. Testing out such a system here, with an internal tool used by a relatively small set of people, is an ideal playground.

What exactly do these permissions look like when you set them up? For an API, I would argue that the *subject* refers to the user invoking an action against the API. The *namespace* and *object* denote what is being targeted by the action. And the *relation* is, generally speaking, the action itself.

Let's imagine a *subject* called `_authd` which represents any authenticated user. An authenticated user then wants to sync a Stripe subscription, i.e. they want to force an association between an internal subscription and a Stripe subscription. Let's say the we have a generic *relation*, `edit`, that implies you can modify a resource. What are the resources being modified? Two of them: the internal subscription and the Stripe subscription. These are refered to via a *namespace* and *object* identifier: `default:subscription` and `stripe:subscription`, respectively. Following a notation of `namespace:object#relation@subject` we would have something like:

```
mj:subscription#edit@_authd
stripe:subscription#edit@_authd
```

Now let's imagine that we want anyone who can *edit* stripe subscriptions to also be able to *view* stripe subscriptions. We can do that via *subject sets*, which allow a transitive relationship to be created.

```
stripe:subscription#view@stripe:subscription#edit
```

This tells the system, any *subject* associated with `stripe:subscription#edit` is to be also associated with `stripe:subscription#view`. This is great for hierarchical relationships, where having the ability to do, or have access to, one thing implies you have the ability to do, or have access to, other things.

## Up and Running

To start your Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix
