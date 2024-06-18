FROM elixir:1.15-alpine AS base

RUN apk add bash build-base inotify-tools

RUN mix local.hex --force
RUN mix local.rebar --force

WORKDIR /app

ENTRYPOINT ["iex"]
CMD ["-S", "mix"]

FROM base AS build

ENV MIX_ENV=prod

COPY config config
COPY mix.exs .
COPY mix.lock .

RUN mix deps.get --only prod && mix deps.compile && mix tailwind.install

COPY assets assets
COPY priv priv

COPY lib lib

RUN mix compile && mix assets.deploy

ENTRYPOINT ["mix"]
CMD ["phx.server"]
