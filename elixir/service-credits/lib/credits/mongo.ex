defmodule Credits.Mongo do
  @moduledoc """
  A wrapper around the `Mongo` library. Is intended to have a similar interface to `Ecto.Repo` and works with `Ecto.Query` and `Ecto.Changeset` structs.
  """

  alias Credits.Schema.{ExpiringCredit, UserCredits}

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
  # Not a complete solution covering all possible query expressions; this is intended only for the sake of an example.
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
  """
  def update(%Ecto.Changeset{data: %UserCredits{}} = changeset), do: changeset |> Ecto.Changeset.apply_changes() |> update()

  def update(%UserCredits{user_id: user_id} = state) do
    # Generate a valid `$set` object and update the database.
  end
end
