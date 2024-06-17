defmodule Credits.UserTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Credits.User
  alias Credits.Schema.UserCredits

  test "complete job when not charging credits" do
    state = Forge.create(%UserCredits{}, false)

    result =
      Forge.create(:job, false)
      |> Map.put("event", %{"charge_credits" => false})
      |> User.complete_job(state)

    assert is_nil(result)
  end

  test "complete job when there are no machine durations present" do
    state = Forge.create(%UserCredits{}, false)
    job = Forge.create(:job, false)

    result =
      job
      |> Map.put("machine_durations", nil)
      |> User.complete_job(state)

    assert is_nil(result)

    result =
      job
      |> Map.put("machine_durations", %{})
      |> User.complete_job(state)

    assert is_nil(result)
  end

  # We use properties to test the individual parts of the complete_job/2 function,
  # So this is just a sanity check to ensure we *can* complete a job, not to ensure
  # all jobs result in a completion. Might change this in the future, but it's
  # sufficient for now.
  test "complete job" do
    state =
      Forge.create(%UserCredits{}, false)
      |> Map.put(:trial, 0)
      |> Map.put(:expiring, [])
      |> Map.put(:period, 2000)

    job =
      Forge.create(:job, false)
      |> Map.put("type", "v6_diffusion")
      |> Map.put("machine_durations", %{"a6000c" => 1.0})
      |> Map.put("event", %{})
      |> Map.put("low_priority", false)

    assert {changeset, 1000, 1000, 0} = User.complete_job(job, state)
    lifetime = 1000 + state.lifetime_total
    assert %{period: 1000, lifetime_total: ^lifetime} = changeset.changes
  end
end
