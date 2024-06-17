defmodule Credits.User do
  @moduledoc """
  A Horde Process implementation that stores the state of a user's credits.
  """

  require Logger

  # 1 hour process timeout (in milliseconds).
  @timeout 3_600_000

  use Horde.Process, supervisor: Credits.UserSupervisor, registry: Credits.UserRegistry, wait_max: 0

  alias Credits
  alias Credits.Repo
  alias Credits.Schema.UserCredits
  alias Events.ChangeTracking

  defstruct user_id: nil,
            credits: %UserCredits{},
            next_expiration: nil,
            expiry_timer: nil

  @type t :: %__MODULE__{
          user_id: String.t(),
          credits: UserCredits.t(),
          next_expiration: DateTime.t() | nil,
          expiry_timer: reference() | nil
        }

  @doc """
  Returns the user's current credits and their lifetime total usage.
  """
  @spec credits(String.t()) :: map()
  def credits(user_id), do: call!(user_id, :credits)

  @doc """
  Consumes credits for the completion of a job.

  This is an asynchronous operation and will immediately return `:ok`.
  """
  @spec complete(String.t(), map()) :: :ok
  def complete(user_id, job), do: cast!(user_id, {:complete, job})

  @doc """
  Same as `grant(user_id, grants, %{})`.
  """
  @spec grant(String.t(), map()) :: UserCredits.t()
  def grant(user_id, grants), do: call!(user_id, grants)

  @doc """
  Returns the `{:via, _, _}` tuple that is used to register a user process.
  """
  def reg_name(user_id), do: {:via, Horde.Registry, {Credits.UserRegistry, user_id}}

  @impl Horde.Process
  def process_id(%{"user_id" => user_id}), do: user_id
  def process_id(%{user_id: user_id}), do: user_id
  def process_id(user_id) when is_binary(user_id), do: user_id

  @impl Horde.Process
  def child_spec(user_id) do
    %{
      id: user_id,
      start: {__MODULE__, :start_link, [user_id]},
      restart: :temporary,
      shutdown: 10_000
    }
  end

  @impl GenServer
  # Set up the process state quickly and have `handle_continue/2` do the rest.
  def init(user_id) do
    Process.flag(:trap_exit, true)
    {:ok, String.trim(user_id), {:continue, :init}}
  end

  @impl GenServer
  # Handles asynchronous initialization of the process.
  def handle_continue(:init, user_id) when is_binary(user_id) do
    case Repo.fetch(user_id) do
      nil ->
        Logger.warning("Could not find credits for user #{user_id} - stopping user process",
          user_id: user_id
        )

        {:stop, :normal, user_id}

      new_state ->
        # Sanity-op, sort and expire expiring credits real quick.
        {:ok, credits} =
          new_state
          |> Credits.expire(true)
          |> Repo.update()

        credits
        |> update_credits(%__MODULE__{user_id: user_id})
        |> noreply_with_timeout()
    end
  end

  @impl GenServer
  # If we receive a timeout message, stop the process.
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  # If we receive an "expire" message, it means one or more expiring credits need to be expired.
  def handle_info(:expire, state) do
    Logger.debug("Received expiration timer message",
      user_id: state.user_id
    )

    credits =
      case Credits.expire(state.credits) do
        %{changes: []} ->
          Logger.debug("No credits to expire",
            user_id: state.user_id
          )

          noreply_with_timeout(state)

        changeset ->
          Logger.info("Expiring credits for user",
            user_id: state.user_id
          )

          {:ok, schema} = Repo.update(changeset)

          schema
          |> update_credits(state)
          |> noreply_with_timeout()
      end
  end

  # Log Horde conflicts before stopping the process.
  def handle_info({:EXIT, _from, {:name_conflict, _, _, _}}, state) do
    # handle the message, add some logging perhaps, and probably stop the GenServer.
    Logger.warning("Horde name conflict detected, stopping user process",
      user_id: state.user_id
    )

    {:stop, :normal, state}
  end

  # Ignore all other info messages.
  def handle_info(_, state), do: state

  @impl GenServer
  # Fetches the current state of the user's credits.
  def handle_call(:credits, _from, state) do
    {:reply, state.credits, state}
  end

  # Grants credits to a user.
  def handle_call({:grant, grants}, _from, state) do
    Logger.info("Granting credits",
      user_id: state.user_id,
      grants: grants
    )

    case Credits.grant(grants, state.credits) do
      %{changes: changes} when map_size(changes) == 0 ->
        reply_with_timeout(state)

      changeset ->
        {:ok, schema} = Repo.update(changeset)

        schema
        |> update_credits(state)
        |> reply_with_timeout()
    end
  end

  @impl GenServer
  # Make a quick check that the job being completed belongs to this user.
  def handle_cast(
        {:complete, %{"id" => job_id, "user_id" => user_id} = job},
        %{user_id: user_id, credits: credits} = state
      ) do
    case complete_job(job, credits) do
      # Nil means the cost when <= 0, so we didn't need to deduct anything.
      nil ->
        Logger.info("Job completed without charging credits",
          user_id: user_id,
          job_id: job_id,
          job: job
        )

        noreply_with_timeout(state)

      # No changes means nothing happened, which is weird, log a warning and pass.
      {%{changes: changes}, _, _, _} when map_size(changes) == 0 ->
        Logger.warning("Job completed without any changes",
          user_id: user_id,
          job_id: job_id,
          job: job
        )

        noreply_with_timeout(state)

      # The standard case, we deducted some credits, log it and update the database.
      {changeset, actual_cost, cost, remainder} ->
        Logger.info("Job completed, charging user",
          user_id: user_id,
          job_id: job["id"],
          cost: cost,
          job: job
        )

        case Repo.update(changeset) do
          {:ok, schema} ->
            # Persist the updated credits in the process state.
            schema
            |> update_credits(state)
            |> noreply_with_timeout()

          _ ->
            # No changes made, move on.
            noreply_with_timeout(state)
        end
    end
  end

  def handle_cast(_, state), do: noreply_with_timeout(state)

  @doc """
  Updates the user process state with updated user credits.

  This will also potentially set a new expiry timer. If the user has a list of expiring credits, they are assumed to be sorted by expiration date.
  """
  @spec update_credits(UserCredits.t(), t()) :: t()
  def update_credits(%UserCredits{expiring: []} = credits, state), do: %{state | credits: credits}

  def update_credits(%{expiring: [next | _]} = credits, %{next_expiration: nil} = state) do
    time = max(0, DateTime.diff(next.expires_at, DateTime.utc_now(), :millisecond))

    # Note: when passing a PID (such as via `self/0`), the timer will automatically cancel if the process exits.
    # This means we don't have to clean up the timer manually when the process terminates.
    expiry_timer = Process.send_after(self(), :expire, time)

    %{state | credits: credits, next_expiration: next.expires_at, expiry_timer: expiry_timer}
  end

  def update_credits(%{expiring: [next | _]} = credits, %{next_expiration: exp} = state) do
    if DateTime.compare(next.expires_at, exp) != :eq do
      Process.cancel_timer(state.expiry_timer, async: true, info: false)

      update_credits(credits, %{state | next_expiration: nil, expiry_timer: nil})
    else
      %{state | credits: credits}
    end
  end

  # Constructs a `:reply` tuple with `new_state.credits` as the reply term.
  defp reply_with_timeout(new_state), do: {:reply, new_state.credits, new_state, @timeout}

  # Constructs a `:noreply` tuple.
  defp noreply_with_timeout(new_state), do: {:noreply, new_state, @timeout}

  @doc """
  Completes a job with the current state of the user's credits. This will return either `nil` if no changes were made to the user's credits, or a tuple of the form `{changeset, actual_cost, capped_cost, remainder}`.
  """
  @spec complete_job(map(), UserCredits.t()) :: {Ecto.Changeset.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil

  # Nothing to do, we don't charge credits.
  def complete_job(%{"charge_credits" => false}, _), do: nil

  # We do charge credits, so calculate the cost and deduct them from the user's credits.
  def complete_job(%{"id" => job_id, "type" => job_type} = job, state) do
    # Calculate both the *actual* cost and the capped cost.
    actual_cost = Map.get(job, "cost", 0)
    capped_cost = Credits.type_cap(job_type)

    if actual_cost != capped_cost do
      Logger.info(
        "Capping cost for job #{job_id} from #{actual_cost} to #{capped_cost}",
        user_id: state.user_id,
        job_id: job_id,
        job: job,
        actual_cost: actual_cost,
        cost: capped_cost
      )
    end

    # Deduct the cost and handle the result.
    {changeset, remainder} = Credits.deduct(capped_cost, state)

    # Uh-oh, we have some uncharged leftover, log it.
    if remainder > 0 do
      Logger.warning(
        "Job completed, user did not have enough credits to cover the full cost",
        user_id: state.user_id,
        job_id: job_id,
        cost: capped_cost,
        remainder: remainder
      )
    end

    {changeset, actual_cost, capped_cost, remainder}
  end
end
