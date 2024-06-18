defmodule Inneal.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      InnealWeb.Telemetry,
      # Start the Ecto repository
      Inneal.Repo,
      Inneal.Credits.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Inneal.PubSub},
      # Start the Endpoint (http/https)
      InnealWeb.Endpoint,
      # Start Finch http client (used by Goth)
      {Finch, name: Inneal.Finch},
      # Start the Goth client for Google Cloud auth token management
      {Goth, name: Inneal.Goth},
      # Start the Firebase Key Server so that we can verify tokens from Identity Platform
      {Inneal.FirebaseKeyServer, name: Inneal.FirebaseKeyServer},
      # Start the Mongo client
      {Mongo, Inneal.Mongo.Repo.config(:billing)},
      # Start a worker by calling: Inneal.Worker.start_link(arg)
      # {Inneal.Worker, arg},
      # Start the NATS connection supervisor
      %{
        id: Gnat.ConnectionSupervisor,
        start:
          {Gnat.ConnectionSupervisor, :start_link,
           [
              Application.fetch_env!(:inneal, :nats),
           ]}
      },
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Inneal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InnealWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
