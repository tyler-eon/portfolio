FROM elixir:1.16-alpine as base

WORKDIR /app

RUN apk add --no-cache ca-certificates

RUN mix local.hex --force && \
    mix local.rebar --force

ENTRYPOINT ["mix"]
CMD ["run", "--no-halt"]

FROM base as build

ARG MIX_ENV
ENV MIX_ENV=${MIX_ENV:-prod}

COPY mix.exs mix.lock .

RUN mix deps.get && mix deps.compile

COPY config config
COPY rel rel
COPY lib lib

RUN mix release credits

FROM alpine:3.19 as deploy

ARG MIX_ENV
ENV MIX_ENV=${MIX_ENV:-prod}

RUN apk add --no-cache gcc ncurses openssl

WORKDIR /app

COPY --from=build /app/_build/${MIX_ENV}/rel/credits .

ENTRYPOINT ["bin/credits"]
CMD ["start"]
