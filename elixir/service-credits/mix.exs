defmodule Credits.MixProject do
  use Mix.Project

  def project do
    [
      app: :credits,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        credits: [
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:mix, :logger],
      mod: {Credits.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:horde, "~> 0.8"},
      {:horde_process, "~> 0.1"},
      {:libcluster, "~> 3.3"},
      {:broadway, "~> 1.0"},
      {:ecto, "~> 3.10"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:logger_json, "~> 5.1"},
      {:stream_data, "~> 0.6", only: [:test], runtime: false}
    ]
  end
end
