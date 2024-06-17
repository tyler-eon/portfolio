ExUnit.start()

defmodule Forge do
  @moduledoc """
  Helper module that creates structs for testing. Can also create generators for use with `StreamData` and property testing.
  """

  use ExUnitProperties

  alias Credits.Schema.{ExpiringCredit, UserCredits}

  @doc """
  Creates a generator for the given struct. Can be used with `StreamData.list_of` to generate a list of structs.
  """
  def create(struct), do: create(struct, true)

  @doc """
  Create either a single instance of the given struct or a generator for the struct.

  When `true` is passed for the second argument, this function returns a generator for the struct. When `false` is passed, the `pick/1` function is used to return a single random instance of the struct from its generator.
  """
  def create(struct, false), do: struct |> create(true) |> pick()

  def create(%ExpiringCredit{}, true) do
    gen all(
          initial <- StreamData.integer(0..1000),
          amount <- StreamData.integer(max(initial - 1000, 0)..initial),
          created <- timestamp_range(86400, 86400),
          expires <- timestamp_range(created, 0, 86400),
          note <- StreamData.binary()
        ) do
      %ExpiringCredit{
        initial: initial,
        amount: amount,
        created_at: DateTime.from_unix!(created),
        expires_at: DateTime.from_unix!(expires),
        note: note
      }
    end
  end

  def create(%UserCredits{}, true) do
    gen all(
          rollover <- StreamData.integer(0..1000),
          trial <- StreamData.integer(0..1000),
          period <- StreamData.integer(0..1000),
          relax <- StreamData.integer(-1000..0),
          expiring <- list(%ExpiringCredit{}),
          lifetime <- StreamData.integer(0..100_000)
        ) do
      user_id = Ecto.UUID.generate()

      %UserCredits{
        user_id: user_id,
        rollover: rollover,
        trial: trial,
        period: period,
        relax: relax,
        expiring: Enum.map(expiring, &Map.put(&1, :user_id, user_id)),
        lifetime_total: lifetime
      }
    end
  end

  def create(:entitlement, true) do
    type_list = const_list(["trial", "expiring", "period", "rollover", "relax", "invalid"])

    gen all(
          kind <- StreamData.one_of([StreamData.constant("credits"), StreamData.binary()]),
          bucket <- StreamData.one_of(type_list),
          seconds <- StreamData.integer(-1000..1000),
          expires <- StreamData.integer(0..1000)
        ) do
      %{
        # We should expect to potentially get non-credits entitlements.
        "kind" => kind,
        "bucket" => bucket,
        "amount" => %{"seconds" => seconds},
        # Should be ignored for non-expiring credits.
        "expires" => %{"seconds" => expires}
      }
    end
  end

  def create(:grant, true) do
    type_list = const_list([:trial, :expiring, :period, :rollover, :relax])

    gen all(
          bucket <- StreamData.one_of(type_list),
          amount <- StreamData.integer(-1000..1000),
          expires <- timestamp_range(86400, 86400)
        ) do
      case bucket do
        :expiring ->
          {:expiring,
           %{
             amount: amount,
             initial: amount,
             expires_at: expires,
             note: StreamData.binary()
           }}

        _ ->
          {bucket, amount}
      end
    end
  end

  def create(:job, true) do
    machine_types =
      Application.get_env(:credits, :costs)
      |> Map.keys()
      |> Forge.const_list()

    job_types =
      Application.get_env(:credits, :caps)
      |> Keyword.values()
      |> List.flatten()
      |> Forge.const_list()

    event_opts =
      const_list([
        %{},
        %{"charge_credits" => true},
        %{"charge_credits" => false},
        %{"turbo" => false, "quiz" => false},
        %{"turbo" => true, "quiz" => false},
        %{"turbo" => false, "quiz" => true},
        %{"turbo" => true, "quiz" => true}
      ])

    gen all(
          relax <- StreamData.boolean(),
          machine_durations <-
            StreamData.map_of(StreamData.one_of(machine_types), StreamData.float(min: 0, max: 60), min_length: 0, max_length: 2),
          type <- StreamData.one_of(job_types),
          event <- StreamData.one_of(event_opts)
        ) do
      %{
        "id" => Ecto.UUID.generate(),
        "user_id" => Ecto.UUID.generate(),
        "low_priority" => relax,
        "machine_durations" => machine_durations,
        "type" => type,
        "event" => event
      }
    end
  end

  @doc """
  Creates a list of "constant value generators" by mapping each list element using `StreamData.constant/1`.

  **Important**: The returned list is *not* a generator, just a list of "constant value generators".
  """
  def const_list(list), do: Enum.map(list, &StreamData.constant(&1))

  @doc """
  Invokes `timestamp_range/3` using the current time as the anchor date.
  """
  def timestamp_range(pre, post), do: timestamp_range(DateTime.utc_now() |> DateTime.to_unix(), pre, post)

  @doc """
  Returns an integer generator using the given "date range", i.e. the an anchor unix timestamp value and some arbitrary number of seconds before and after the anchor.
  """
  def timestamp_range(anchor, pre, post), do: StreamData.integer((anchor - pre)..(anchor + post))

  @doc """
  Uses `StreamData.list_of` to create a list generator for a struct generator (via `create/1`). Defaults to `min_length` of 0 and `max_length` of 4.
  """
  def list(struct, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:min_length, 0)
      |> Keyword.put_new(:max_length, 4)

    StreamData.list_of(create(struct), opts)
  end
end
