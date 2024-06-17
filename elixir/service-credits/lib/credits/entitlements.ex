defmodule Credits.Entitlements do
  @moduledoc """
  Functions related to entitlements. Entitlements can be used to add, subtract, or set credits depending on the bucket being modified and the value of the entitlement.
  """

  @kind_credits "credits"

  @doc """
  Converts one or more entitlements to a map that resembles the credit structure of `Credits.User`.

  Entitlements are expected to be in the following format:

  ```json
  {
    "kind": "credits",
    "bucket": "trial",
    "amount": {
      "hours": 1
    }
  }
  ```

  The `kind` must always be set to `credits`.

  The `amount` is a map that specifies how much time to grant. See `map_to_seconds/1` for details about the acceptable format for `amount`.

  The `bucket` must be one of: `expiring`, `trial`, `permanent`.

  If `bucket` is set to `expiring`, then there must be an additional key in the entitlement: `expires`. The value for `expires` should be in the same format as `amount` and represents how long from the time at which it is granted until the credit expires.
  """
  @spec convert([map()]) :: map()
  def convert([]), do: %{}

  # If we have a list of entitlements, convert each one and merge the final results.
  def convert(entitlements) when is_list(entitlements) do
    Enum.reduce(entitlements, %{}, fn e, acc ->
      Map.merge(acc, convert(e), fn
        # Expiring credits are stored as lists, concat when merging.
        :expiring, v1, v2 ->
          v1 ++ v2

        # All other credits are integers, simply add.
        _key, v1, v2 ->
          v1 + v2
      end)
    end)
  end

  # Expiring credits are handled differently to due the additional metadata required.
  def convert(
        %{"kind" => @kind_credits, "bucket" => "expiring", "amount" => amount, "expires" => exp} =
          entitlement
      ) do
    # Convert the value to milliseconds.
    value = trunc(map_to_seconds(amount) * 1_000)

    # Use an given creation timestamp if available, or use the current time as a default
    created =
      case Map.get(entitlement, "created") do
        nil -> DateTime.utc_now()
        tms -> DateTime.from_unix!(round(tms / 1000))
      end

    # Create the expiration timestamp.
    expires =
      case exp do
        nil ->
          # We default to 30-day expiration if nothing is provided.
          DateTime.add(created, 30, :day)

        e when is_integer(e) ->
          # This is the "old style" where you supply the expiration as a milliseconds unix timestamp.
          DateTime.from_unix!(round(e / 1000))

        m when is_map(m) ->
          # This is the "new style" where you supply the expiration as a map of time units.
          DateTime.add(created, map_to_seconds(m), :second)
      end

    # Create an expiring credit.
    %{
      expiring: [
        %{
          initial: value,
          amount: value,
          created_at: created,
          expires_at: expires,
          note: Map.get(entitlement, "note")
        }
      ]
    }
  end

  def convert(%{"kind" => @kind_credits, "bucket" => bucket, "amount" => amount}) do
    # Create a credit matching the requested bucket.
    value = trunc(map_to_seconds(amount) * 1_000)

    case bucket do
      "permanent" -> %{permanent: value}
      "trial" -> %{trial: value}
      _ -> %{}
    end
  end

  # If we got a non-credit entitlement, just ignore it.
  def convert(_), do: %{}

  @doc """
  Converts a map of `unit => value` pairs to an integer value representing the mapped time offset as number of seconds.

  For example, `%{"hours" => 2, "minutes": 30}` would return `9_000`, because 2.5 hours is equal to 9,000 seconds.

  Output may be a floating-point value.

  **Note**: Only supports the following units of time:

  - seconds
  - minutes
  - hours
  - days
  - weeks

  This function only works with units of time that have a fixed value for the number of seconds they contain.
  """
  @spec map_to_seconds(map()) :: number()
  def map_to_seconds(map),
    do: Enum.reduce(map, 0, fn pair, acc -> acc + tuple_to_seconds(pair) end)

  @doc """
  Takes a key-value tuple and return an integer representing some number of seconds. See `map_to_seconds/1` for valid "keys".
  """
  @spec tuple_to_seconds({String.t(), number()}) :: number()
  def tuple_to_seconds({"seconds", s}), do: s
  def tuple_to_seconds({"minutes", m}), do: m * 60
  def tuple_to_seconds({"hours", h}), do: h * 3600
  def tuple_to_seconds({"days", d}), do: d * 86_400
  def tuple_to_seconds({"weeks", w}), do: w * 604_800
end
