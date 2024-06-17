defmodule Credits do
  @moduledoc """
  Manages user credits. This is a zero side-effect module, meaning it does not cause any external changes, e.g. writing to a database.
  """

  # The order in which to charge credits.
  @charge_order [
    :trial,
    :expiring,
    :permanent
  ]

  alias Ecto.Changeset
  alias Credits.Schema.{ExpiringCredit, UserCredits}

  require Logger

  @doc """
  Constructs a changeset for the given `UserCredits` state with pending changes based on the `credits` grant mapping.
  """
  @spec grant(grants :: map, credits :: UserCredits.t()) :: Changeset.t()
  def grant(grants, %UserCredits{} = credits) when map_size(grants) == 0, do: Changeset.change(credits)

  def grant(grants, %UserCredits{} = credits) do
    # Create a changeset for all the updated credits
    Enum.reduce(grants, Changeset.change(credits), fn
      # Add expiring credits to the list and ensure it is sorted properly.
      {:expiring, val}, cs ->
        Changeset.put_change(cs, :expiring, merge_expiring(credits.expiring, sort_expiring(val)))

      # All other credits are cumulative. Use `max/2` to ensure we don't have negative credits.
      {kind, val}, cs ->
        Changeset.put_change(cs, kind, max(Map.get(credits, kind, 0) + val, 0))
    end)
  end

  @doc """
  Deducts `cost` from the given `UserCredits` state, returning a changeset with the pending changes and the number the remainder, i.e. the number of credits that that could not be deducted from the given cost.

  If `cost` is less than or equal to zero, `nil` is returned.
  """
  @spec deduct(cost :: non_neg_integer(), credits :: UserCredits.t()) :: {Changeset.t(), non_neg_integer()} | nil
  def deduct(cost, _) when cost <= 0, do: nil

  def deduct(cost, %UserCredits{} = credits) do
    # Start a changeset that tracks individual changes to the various credit buckets.
    changeset = Ecto.Changeset.change(credits)

    # We only need to build up the changeset until either (a) we've covered the full cost or (b) we've run out of credits.
    Enum.reduce_while(@charge_order, {changeset, cost}, fn
      _key, {changeset, debit} when debit <= 0 ->
        {:halt, {changeset, 0}}

      :expiring, {changeset, debit} ->
        {:cont, charge_expiring(changeset, debit)}

      key, {changeset, debit} ->
        {:cont, charge_bucket(changeset, key, debit)}
    end)
  end

  @doc """
  Same as calling `expire(credits, false)`.
  """
  @spec expire(credits :: UserCredits.t() | [ExpiringCredit.t()]) :: Ecto.Changeset.t() | [ExpiringCredit.t()]
  def expire(credits), do: expire(credits, false)

  @doc """
  Expire any expiring credits that have passed their expiration date.

  When `sort` is set to `true`, the expiring credits will also be sorted by expiration date if they aren't already. Otherwise, it is assumed that the list of expiring credits is already sorted in ascending order by expiration date.

  When given a `UserCredits` struct, a changeset with the updated expiring credits list will be returned. When given a list of expiring credits, a new list with only non-expired (and optionally sorted) credits will be returned.
  """
  @spec expire(credits :: UserCredits.t() | [ExpiringCredit.t()], sort :: boolean) :: Ecto.Changeset.t() | [ExpiringCredit.t()]
  def expire(%UserCredits{} = credits, sort) do
    Ecto.Changeset.change(credits, expiring: expire(credits.expiring, sort))
  end

  def expire([], _), do: []

  def expire(credits, true) when is_list(credits) do
    credits
    |> sort_expiring()
    |> expire(false)
  end

  def expire(credits, _) when is_list(credits) do
    now = DateTime.utc_now()
    Enum.drop_while(credits, fn %{expires_at: expires} -> DateTime.compare(expires, now) != :gt end)
  end

  @doc """
  Sorts a list of expiring credits in ascending order by expiration date.

  When given a `UserCredits` struct, a changeset with the updated expiring credits list will be returned. When given a list of expiring credits, a new list with the sorted credits will be returned.
  """
  @spec sort_expiring(credits :: UserCredits.t() | [ExpiringCredit.t()]) :: Ecto.Changeset.t() | [ExpiringCredit.t()]
  def sort_expiring(%UserCredits{} = credits) do
    Ecto.Changeset.change(credits, expiring: sort_expiring(credits.expiring))
  end

  def sort_expiring(credits) when is_list(credits), do: Enum.sort_by(credits, & &1.expires_at, DateTime)

  @doc """
  Merges two *already sorted* lists of expiring credits. Again, each list is assumed to be sorted in ascending order by expiration date.
  """
  def merge_expiring(exp1, exp2, acc \\ [])

  def merge_expiring([], [], acc), do: Enum.reverse(acc)

  def merge_expiring([], [c2 | exp2], acc), do: merge_expiring([], exp2, [c2 | acc])

  def merge_expiring([c1 | exp1], [], acc), do: merge_expiring(exp1, [], [c1 | acc])

  def merge_expiring([c1 | exp1], [c2 | exp2], acc) do
    if DateTime.compare(c1.expires_at, c2.expires_at) == :lt do
      merge_expiring(exp1, [c2 | exp2], [c1 | acc])
    else
      merge_expiring([c1 | exp1], exp2, [c2 | acc])
    end
  end

  @doc """
  Charges a user's expiring credits.

  When charging expiring credits, we need to ensure that any expired credits are removed and not used to cover the cost. However, we assume that the list of expiring credits is already sorted appropriately.

  Returns the updated list of expiring credits and any remaining cost that wasn't covered.
  """
  @spec charge_expiring(changes :: Ecto.Changeset.t(), debit :: non_neg_integer) ::
          {[Ecto.Changeset.t()], remainder :: non_neg_integer}
  def charge_expiring(%Ecto.Changeset{data: credits} = changeset, debit) do
    {expiring_updated, remainder} =
      credits.expiring
      # Iterate over the list consuming credits until either (a) the debit is fully consumed or (b) we run out of credits.
      |> Enum.reduce({[], debit}, fn
        credit, {new_credits, 0} ->
          # No remaining debt, skip everything else.
          {[credit | new_credits], 0}

        %{amount: amount}, acc when amount < 0 ->
          # Drop credits with negative amounts.
          acc

        %{amount: amount} = credit, {new_credits, debit} ->
          if amount > debit do
            # Can cover the entire remaining debt with zeroing out the credit.
            {[%{credit | amount: amount - debit} | new_credits], 0}
          else
            # The credit is fully consumed and we have zero or more debt remaining.
            {new_credits, debit - amount}
          end
      end)

    # Return the (correctly-ordered) updated list of expiring credits and any remaining cost that wasn't covered.
    {Changeset.put_embed(changeset, :expiring, Enum.reverse(expiring_updated)), remainder}
  end

  @doc """
  Charges the given credit bucket. Post-debited values are always zero or more.

  Returns the updated changeset and any remaining cost that wasn't covered by the given credit bucket.
  """
  @spec charge_bucket(changeset :: Ecto.Changeset.t(), bucket :: atom, debit :: non_neg_integer) ::
          {Ecto.Changeset.t(), remainder :: non_neg_integer}
  def charge_bucket(%Ecto.Changeset{data: credits} = changeset, bucket, debit) do
    {new_value, rem} =
      case Map.get(credits, bucket, 0) do
        value when value > 0 and value >= debit ->
          # Can cover the entire remaining debt
          {value - debit, 0}

        value when value > 0 ->
          # Can cover only part of the remaining debt
          {0, debit - value}

        value ->
          # Can't cover any of the remaining debt
          {value, debit}
      end

    {Ecto.Changeset.put_change(changeset, bucket, new_value), rem}
  end

  @doc """
  Given a job type, returns the maximum number of credits to be charged in seconds.

  Defaults to 300 seconds (5 minutes) if there's no cap defined for the given job type.
  """
  @spec type_cap(String.t()) :: number()

  :credits
  |> Application.compile_env!(:caps)
  |> Enum.each(fn {cap, types} ->
    Enum.each(types, fn type ->
      def type_cap(unquote(type)), do: unquote(cap)
    end)
  end)

  def type_cap(_), do: 300
end
