defmodule Credits.Repo do
  @moduledoc """
  The primary credits/finance data repository. Stores user credit state and related financial data, such as credit change history.
  """

  use Ecto.Repo,
    otp_app: :credits,
    adapter: Ecto.Adapters.Postgres

  require Logger

  alias Credits.Schema.{ExpiringCredit, UserCredits}

  import Ecto.Query

  def init(_type, config) do
    config =
      config
      |> Keyword.put(:url, System.fetch_env!("DATABASE_URL"))
      |> Keyword.put(:ssl, true)
      |> Keyword.put(:ssl_opts, verify: :verify_none)
      |> Keyword.put(:pool_size, System.get_env("POOL_SIZE", "10") |> String.to_integer())

    {:ok, config}
  end

  @doc """
  Fetches the credit state for a user.

  This will first attempt to fetch from the Postgres database. If no record is found, it will attempt to fetch from MongoDB and also insert the fetched state of the user into Postgres for future fetches.
  """
  def fetch(user_id) do
    case get(UserCredits, user_id) do
      nil ->
        credits =
          case get_from_mongo(user_id) do
            nil ->
              %UserCredits{user_id: user_id}

            uc ->
              uc
          end

        insert(credits, conflict_target: :user_id, on_conflict: {:replace_all_except, [:user_id]})
        credits

      res ->
        res
    end
  end

  @doc """
  Fetches the credit state from mongodb.
  """
  def get_from_mongo(user_id) do
    query =
      from(uc in UserCredits,
        where: uc.user_id == ^user_id,
        join: ec in ExpiringCredit,
        on: ec.user_id == uc.user_id
      )

    Mongo.one(query)
  end

  @doc """
  Update the credit state for a user via an `Ecto.Changeset` struct.
  """
  # TODO: Once we no longer rely on MongoDB for any of this data, we can remove this function and just use `update/1` instead.
  def update2(%Ecto.Changeset{} = changeset) do
    %Mongo.UpdateResult{modified_count: m} = Mongo.update(changeset)

    if m != 1 do
      Logger.warning("Failed to update mongodb with user credit state", user_id: changeset.data.user_id)
    end

    try do
      res = update!(changeset)
      Logger.info("User credits updated", user_id: res.user_id, result: res)
      {:ok, res}
    rescue
      Ecto.StaleEntryError ->
        Logger.warning("Failed to update user credit state, trying insert instead.", user_id: changeset.data.user_id)
        res = insert!(changeset)
        Logger.info("User credits updated", user_id: res.user_id, result: res)
        {:ok, res}
    end
  end
end
