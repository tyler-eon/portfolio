defmodule Credits.Repo do
  @moduledoc """
  The primary credits/finance data repository. Stores user credit state and related financial data, such as credit change history.
  """

  use Ecto.Repo,
    otp_app: :credits,
    adapter: Ecto.Adapters.Postgres

  def init(_type, config) do
    config =
      config
      |> Keyword.put(:url, System.fetch_env!("DATABASE_URL"))
      |> Keyword.put(:ssl, true)
      |> Keyword.put(:ssl_opts, verify: :verify_none)
      |> Keyword.put(:pool_size, System.get_env("POOL_SIZE", "10") |> String.to_integer())

    {:ok, config}
  end
end
