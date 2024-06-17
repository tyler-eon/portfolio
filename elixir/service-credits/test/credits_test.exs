defmodule CreditsTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Credits
  alias Credits.Entitlements
  alias Credits.Schema.{ExpiringCredit, UserCredits}

  property "grant credits" do
    base_state = Forge.create(%UserCredits{}, false)

    check all(grants <- Forge.list(:grant)) do
      # Convert the list of {bucket, value} tuples to a map.
      grants = Entitlements.convert(grants)

      # Grant the credits and ensure the user was updated properly.
      credits = Credits.grant(grants, base_state) |> Ecto.Changeset.apply_changes()

      Enum.each([:trial, :expiring, :period, :rollover, :relax], fn
        :expiring ->
          assert length(credits.expiring) == length(Map.get(grants, :expiring, [])) + length(base_state.expiring)

        :relax ->
          assert credits.relax == min(0, Map.get(grants, :relax, 0) + base_state.relax)

        :period ->
          assert credits.period == max(Map.get(grants, :period, base_state.period), 0)

        bucket ->
          assert Map.get(credits, bucket, 0) == max(0, Map.get(grants, bucket, 0) + Map.get(base_state, bucket, 0))
      end)
    end
  end

  property "charging expiring credits" do
    base_state = Forge.create(%UserCredits{}, false)

    check all(
            credits <- Forge.list(%ExpiringCredit{}),
            cost <- StreamData.integer(0..60000)
          ) do
      credits = Credits.sort_expiring(credits)
      state = Map.put(base_state, :expiring, credits)

      {changeset, rem} =
        state
        |> Ecto.Changeset.change()
        |> Credits.charge_expiring(cost)

      case credits do
        [] ->
          assert is_nil(changeset.changes[:expiring])
          assert rem == cost

        _ ->
          {e, r} =
            Enum.reduce(credits, {[], cost}, fn
              credit, {acc, 0} ->
                {[credit | acc], 0}

              credit, {acc, rem} when credit.amount > rem ->
                {[credit | acc], 0}

              credit, {acc, rem} ->
                {acc, rem - credit.amount}
            end)

          remaining_e = Enum.filter(changeset.changes[:expiring], &(&1.action == :insert))
          assert length(remaining_e) == length(e)
          assert rem == r

          Enum.each(credits, fn
            credit ->
              assert credit.amount >= 0
          end)
      end
    end
  end

  test "expiring credit expiration" do
    credits =
      [
        %ExpiringCredit{
          user_id: "user_id",
          initial: 3_600_000,
          amount: 3_600_000,
          created_at: DateTime.utc_now() |> DateTime.add(-35, :day),
          expires_at: DateTime.utc_now() |> DateTime.add(-5, :day),
          note: "expire"
        },
        %ExpiringCredit{
          user_id: "user_id",
          initial: 3_600_000,
          amount: 3_600_000,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.utc_now() |> DateTime.add(30, :day),
          note: "don't expire"
        }
      ]
      |> Credits.expire()

    assert length(credits) == 1
    assert [%{expires_at: exp}] = credits
    assert DateTime.compare(exp, DateTime.utc_now()) == :gt

    # Ensure we get the same results but wrapped in a `UserCredits` struct when passing a `UserCredits` struct.
    credits = Credits.expire(%UserCredits{expiring: credits})

    assert %UserCredits{expiring: exp} = Ecto.Changeset.apply_changes(credits)
    assert [%{expires_at: e}] = exp
    assert DateTime.compare(e, DateTime.utc_now()) == :gt
  end

  test "expiring credit expiration with sorting" do
    # Credits should get sorted first and then expired.
    credits =
      [
        %ExpiringCredit{
          user_id: "user_id",
          initial: 3_600_000,
          amount: 3_600_000,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.utc_now() |> DateTime.add(30, :day),
          note: "don't expire"
        },
        %ExpiringCredit{
          user_id: "user_id",
          initial: 3_600_000,
          amount: 3_600_000,
          created_at: DateTime.utc_now() |> DateTime.add(-35, :day),
          expires_at: DateTime.utc_now() |> DateTime.add(-5, :day),
          note: "expire"
        },
        %ExpiringCredit{
          user_id: "user_id",
          initial: 3_600_000,
          amount: 3_600_000,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.utc_now() |> DateTime.add(55, :day),
          note: "don't expire"
        }
      ]
      |> Credits.expire(true)

    assert [%{expires_at: exp1}, %{expires_at: exp2}] = credits
    assert DateTime.compare(exp1, DateTime.utc_now()) == :gt
    assert DateTime.compare(exp2, DateTime.utc_now()) == :gt
    assert DateTime.compare(exp2, exp1) == :gt
  end

  test "expiring credits are sorted on grant" do
    base_state = Forge.create(%UserCredits{}, false)

    day1 = DateTime.utc_now() |> DateTime.add(1, :day)
    day2 = DateTime.utc_now() |> DateTime.add(31, :day)
    day3 = DateTime.utc_now() |> DateTime.add(50, :day)

    changeset =
      Credits.grant(
        %{
          expiring: [
            %{
              amount: 1000,
              initial: 1000,
              expires_at: day3
            },
            %{
              amount: 1000,
              initial: 1000,
              expires_at: day1
            }
          ]
        },
        Map.put(base_state, :expiring, [])
      )

    state = Ecto.Changeset.apply_changes(changeset)

    assert %{
             expiring: [
               %{expires_at: ^day1},
               %{expires_at: ^day3}
             ]
           } = state

    changeset =
      Credits.grant(
        %{
          expiring: [
            %{
              amount: 1000,
              initial: 1000,
              expires_at: day2
            }
          ]
        },
        state
      )

    state = Ecto.Changeset.apply_changes(changeset)

    assert %{
             expiring: [
               %{expires_at: ^day1},
               %{expires_at: ^day2},
               %{expires_at: ^day3}
             ]
           } = state
  end

  property "merging expiring credits" do
    check all(
            list1 <- Forge.list(%ExpiringCredit{}),
            list2 <- Forge.list(%ExpiringCredit{})
          ) do
      # Ensure the lists are sorted.
      list1 = Credits.sort_expiring(list1)
      list2 = Credits.sort_expiring(list2)

      # Merge the lists and ensure the result is sorted.
      merged = Credits.merge_expiring(list1, list2)

      assert merged == Credits.sort_expiring(list1 ++ list2)
    end
  end

  property "capped cost" do
    # Convert the {cap, types} list to a mapping of {type => cap}.
    type_caps =
      :credits
      |> Application.get_env(:caps)
      |> Enum.reduce(%{}, fn {cap, types}, acc ->
        Enum.reduce(types, acc, fn type, acc -> Map.put(acc, type, cap) end)
      end)

    check all(
            %{"type" => type} = job <- Forge.create(:job, true),
            duration <- StreamData.integer(10_000..600_000)
          ) do
      turbo = Map.get(job["event"], "turbo", false)
      cost = Credits.capped_cost(duration, type, %{turbo: turbo})

      # Special case turbo jobs are always capped at 20 seconds.
      max = if turbo, do: 20_000, else: trunc(Map.get(type_caps, type, 300) * 1000)

      if duration > max do
        assert cost == max
      else
        assert cost == duration
      end
    end
  end

  property "cost multiplier" do
    check all(%{"machine_durations" => durations, "event" => event} <- Forge.create(:job, true)) do
      case durations do
        %{} ->
          assert true

        _ ->
          Enum.each(durations, fn
            {machine_type, _} ->
              multiplier =
                Credits.cost_multiplier(machine_type, %{
                  quiz: Map.get(event, "quiz", false),
                  turbo: Map.get(event, "turbo", false)
                })

              # Turbo only works on machine types beginning with "quad-". It will 2x your cost.
              expected =
                if String.starts_with?(machine_type, "quad-") and Map.get(event, "turbo", false) do
                  Credits.machine_cost(machine_type) * 2
                else
                  Credits.machine_cost(machine_type)
                end

              # Quiz jobs works on all machine types. It will 0.5x your cost.
              expected = if Map.get(event, "quiz", false), do: expected / 2, else: expected

              assert multiplier == trunc(expected * 1000)
          end)
      end
    end
  end

  test "calculate cost" do
    base_job =
      :job
      |> Forge.create(false)
      |> Map.put("type", "v6_diffusion")
      |> Map.put("event", %{})
      |> Map.put("low_priority", false)

    # One machine type
    assert {500, 500} =
             Credits.calculate_cost(Map.put(base_job, "machine_durations", %{"a100" => 0.5}))

    # Multiple machine types
    assert {2000, 2000} =
             Credits.calculate_cost(Map.put(base_job, "machine_durations", %{"a100" => 0.5, "a6000c" => 1.5}))

    # Multiple machine types with a multiplier expected
    assert {6500, 6500} =
             Credits.calculate_cost(Map.put(base_job, "machine_durations", %{"a100" => 0.5, "quad-a6000c" => 1.5}))

    # Multiple machine types with a multiplier and cost capping expected
    assert {120_000, 60000} =
             Credits.calculate_cost(Map.put(base_job, "machine_durations", %{"a100" => 80, "quad-a6000c" => 10}))

    assert {90000, 60000} =
             Credits.calculate_cost(Map.put(base_job, "machine_durations", %{"a100" => 10, "quad-a6000c" => 20}))
  end
end
