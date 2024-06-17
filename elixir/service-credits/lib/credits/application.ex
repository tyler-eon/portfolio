defmodule Credits.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # We don't want to try starting up unnecessary supervised processes for automated testing.
    if Mix.env() == :test do
      start_test()
    else
      start_normal()
    end
  end

  def start_normal() do
    kafka_config = Application.get_env(:credits, :kafka)

    children = [
      # Start the Credits repo.
      Credits.Repo,

      # Start Horde registry and dynamic supervisor - best to have different registries and different supervisors for different stuff.
      # Ensure `:members` is set to `:auto` so that we use `libcluster` for dynamic cluster management.
      {Horde.Registry, [name: Credits.UserRegistry, keys: :unique, members: :auto]},
      {Horde.DynamicSupervisor, [name: Credits.UserSupervisor, strategy: :one_for_one, members: :auto]},

      # Start the Kafka connection supervisor
      {Events.Kafka, kafka_config},

      # Start the Broadway pipeline
      {Events.Broadway, kafka: kafka_config[:name], subscriptions: kafka_config[:subscriptions]}
    ]

    # Start libcluster, but only when we have a topology config
    children =
      case Application.get_env(:libcluster, :topologies) do
        nil ->
          children

        topologies ->
          [{Cluster.Supervisor, [topologies, [name: Credits.ClusterSupervisor]]} | children]
      end

    opts = [strategy: :rest_for_one, name: Credits.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def start_test() do
    opts = [strategy: :one_for_one, name: Credits.Supervisor]
    Supervisor.start_link([], opts)
  end
end
