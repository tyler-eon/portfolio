defmodule Credits.EntitlementsTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Credits.Entitlements

  property "entitlement conversion to credit grants" do
    check all(entitlements <- Forge.list(:entitlement)) do
      # Convert the constructed set of entitlements into their expected final credit form.
      expected =
        entitlements
        |> Enum.reduce(%{}, fn entitlement, acc ->
          # We have invalid entitlements that we might generate, so those should not be present in the final result.
          if entitlement["kind"] != "credits" or entitlement["bucket"] == "invalid" do
            acc
          else
            value = entitlement["amount"]["seconds"] * 1000

            case String.to_atom(entitlement["bucket"]) do
              :expiring ->
                credit = %{
                  initial: value,
                  amount: value,
                  expires_after: entitlement["expires"]["seconds"],
                  note: entitlement["note"]
                }

                Map.update(acc, :expiring, [credit], &[credit | &1])

              key ->
                Map.update(acc, key, value, &(&1 + value))
            end
          end
        end)
        # Remember to reverse any expiring credits so that they are in the correct order.
        |> Map.update(:expiring, [], &Enum.reverse(&1))

      # Convert the *full* entitlements set (even the invalid ones) into the expected final credit form.
      entitlements
      |> Entitlements.convert()
      |> Enum.map(fn {key, value} -> {key, {Map.get(expected, key), value}} end)
      |> Enum.into(%{})
      |> Enum.each(fn
        # Check that each final credit entitlement was calculated correctly.
        {:expiring, {expect, actual}} ->
          Enum.with_index(expect, fn e, i ->
            a = Enum.at(actual, i)
            assert e.initial == a.initial
            assert e.amount == a.amount
            assert e.expires_after == DateTime.to_unix(a.expires_at) - DateTime.to_unix(a.created_at)
            assert e.note == a.note
          end)

        {_, {expect, actual}} ->
          assert expect == actual
      end)
    end
  end
end
