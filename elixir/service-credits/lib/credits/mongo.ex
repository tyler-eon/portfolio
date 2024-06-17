defmodule Credits.Mongo do
  @moduledoc """
  A wrapper around the `Mongo` library. Is intended to have a similar interface to `Ecto.Repo` and works with `Ecto.Query` and `Ecto.Changeset` structs.
  """

  alias Credits.Schema.{ExpiringCredit, UserCredits}

  def config() do
    [
      name: :mongo,
      url: System.get_env("MONGO_URL", "mongodb://mongo:27017"),
      pool_size: System.get_env("MONGO_POOL_SIZE", "50") |> String.to_integer(),
      database: System.get_env("MONGO_DATABASE", "billing"),
      ssl_opts: [verify: :verify_none, cacerts: :public_key.cacerts_get()]
    ]
  end

  @doc """
  Fetch a single matching Mongo document from a collection based on an Ecto query.
  """
  @spec one(Ecto.Query.t()) :: map()
  def one(%Ecto.Query{from: %{source: {_, schema}}} = query) do
    Mongo.find_one(
      :mongo,
      schema_to_collection(schema),
      convert_query(query)
    )
    |> mongo_to_state()
  end

  @doc """
  Given a valid schema, returns a string representing the Mongo collection name it represents.
  """
  @spec schema_to_collection(atom()) :: String.t()
  def schema_to_collection(UserCredits), do: "user"

  @doc """
  Convert an Ecto query to a Mongo query.

  Only handles the simple case, meaning it only looks at the source "table" (not joins) and the where clauses.
  """
  @spec Ecto.Query.t() :: map()
  def convert_query(%Ecto.Query{wheres: wheres}) do
    wheres
    |> parse_guards()
    |> Enum.reduce(%{}, fn
      {:==, {key, val}}, acc -> Map.put(acc, key, val)
      _, acc -> acc
    end)
  end

  # Convert a list of Ecto query expressions into their simplified forms.
  defp parse_guards(guards) when is_list(guards),
    do: Enum.map(guards, fn guard -> parse_guard(guard) end)

  # Parse a single Ecto query expression into its simplified form.
  defp parse_guard(%Ecto.Query.BooleanExpr{expr: expr, params: params}),
    do: parse_guard(expr, params)

  defp parse_guard({:or, _, terms}, params),
    do: {:or, Enum.map(terms, fn term -> parse_guard(term, params) end)}

  defp parse_guard({:and, _, terms}, params),
    do: {:and, Enum.map(terms, fn term -> parse_guard(term, params) end)}

  defp parse_guard(
         {operator, _,
          [
            {{:., _, [_, field]}, _, _},
            %Ecto.Query.Tagged{value: value}
          ]},
         _params
       ),
       do: {operator, {field, value}}

  defp parse_guard(
         {operator, _,
          [
            {{:., _, [_, field]}, _, _},
            {:^, _, [key]}
          ]},
         params
       ) do
    {value, _} =
      Enum.find(params, fn
        {_, {^key, ^field}} -> true
        _ -> false
      end)

    {operator, {field, value}}
  end

  @doc """
  Update a Mongo document in the `user` collection based on an Ecto Changeset or Schema struct. If a changeset is passed in, `Ecto.Changeset.apply_changes/1` will be called first so that we commit only the most recent user credit state.

  **Note**: Right now only works with the `UserCredits` schema.
  """
  def update(%Ecto.Changeset{data: %UserCredits{}} = changeset), do: changeset |> Ecto.Changeset.apply_changes() |> update()

  def update(%UserCredits{user_id: user_id} = state) do
    Mongo.update_one!(
      :mongo,
      "user",
      %{user_id: user_id},
      %{
        "$set" => %{
          "trial_credits" => state.trial,
          "permanent_credits" => state.permanent,
          "expiring_credits" => Enum.map(state.expiring, &expiring_to_mongo/1),
          "updated" => DateTime.utc_now() |> DateTime.to_unix(:millisecond)
        }
      }
    )
  end

  defp expiring_to_mongo(%ExpiringCredit{} = credit) do
    %{
      "amount" => credit.initial,
      "left" => credit.amount,
      "created" => DateTime.to_unix(credit.created_at, :millisecond),
      "expires" => DateTime.to_unix(credit.expires_at, :millisecond),
      "note" => Map.get(credit, :note)
    }
  end

  # Convert the credit state from a mongodb document to a `UserCredits` Ecto schema.
  @doc """
  Converts a mongo user document to a `UserCredits` struct.
  """
  def mongo_to_state(%{"user_id" => user_id} = muser) do
    %UserCredits{
      user_id: user_id,
      trial: mget_credit(muser, "trial_credits"),
      permanent: mget_credit(muser, "permanent_credits"),
      expiring: expiring_to_state(user_id, Map.get(muser, "expiring_credits", []))
    }
  end

  # Ensures we always return an integer value for a credit amount.
  defp mget_credit(doc, key) do
    case Map.get(doc, key) do
      nil -> 0
      val -> trunc(val)
    end
  end

  # Converts a millisecond-based timestamp integer from mongo to a DateTime struct.
  defp mongo_ts_to_dt(nil), do: nil
  defp mongo_ts_to_dt(%DateTime{} = dt), do: dt
  defp mongo_ts_to_dt(ts), do: ts |> round() |> DateTime.from_unix!(:millisecond)

  # Convert expiring credit data in a mongo user document to a list of expiring credits.
  def expiring_to_state(user_id, expiring) do
    Enum.map(expiring, fn credit ->
      credit = convert_expiring_credit(user_id, credit)

      # Ensure time fields are integers.
      credit = Map.put(credit, :expires_at, mongo_ts_to_dt(credit.expires_at))

      # As of creating this "lazy backfill"...
      # Any entry for expiring credits should only be for the free rating hour which expires after one month.
      # That means any nil created date can be safely set to 30 days prior to the expiration date.
      case credit.created_at do
        nil ->
          created_at =
            credit.expires_at
            |> mongo_ts_to_dt()
            |> DateTime.add(-30, :day)

          Map.put(credit, :created_at, created_at)

        _ ->
          Map.put(credit, :created_at, mongo_ts_to_dt(credit.created_at))
      end
    end)
  end

  # This is the legacy format.
  # TODO: When all existing data has been converted away from this format, we can remove this block.
  defp convert_expiring_credit(
         user_id,
         %{
           "initial" => initial,
           "left" => amount,
           "created" => created_at,
           "expires" => expires_at
         } = credit
       ) do
    %ExpiringCredit{
      user_id: user_id,
      initial: trunc(initial),
      amount: trunc(amount),
      created_at: mongo_ts_to_dt(created_at),
      expires_at: mongo_ts_to_dt(expires_at),
      note: Map.get(credit, "note")
    }
  end

  # This is a *possible* format from an interim period switching from the legacy format to the new one.
  defp convert_expiring_credit(
         user_id,
         %{
           "initial" => initial,
           "amount" => amount,
           "created" => created_at,
           "expires" => expires_at
         } = credit
       ) do
    %ExpiringCredit{
      user_id: user_id,
      initial: trunc(initial),
      amount: trunc(amount),
      created_at: mongo_ts_to_dt(created_at),
      expires_at: mongo_ts_to_dt(expires_at),
      note: Map.get(credit, "note")
    }
  end

  # This is the new format. Due to a bug, `created` might not be present on older entries.
  defp convert_expiring_credit(
         user_id,
         %{
           "amount" => initial,
           "left" => amount,
           "expires" => expires_at
         } = credit
       ) do
    %ExpiringCredit{
      user_id: user_id,
      initial: trunc(initial),
      amount: trunc(amount),
      created_at: mongo_ts_to_dt(Map.get(credit, "created")),
      expires_at: mongo_ts_to_dt(expires_at),
      note: Map.get(credit, "note")
    }
  end
end
