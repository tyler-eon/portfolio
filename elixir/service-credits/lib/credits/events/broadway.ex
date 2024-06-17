defmodule Events.Broadway do
  use Broadway

  alias Broadway.Message
  alias Credits.{Entitlements, User}

  require Logger

  @doc """
  Starts a Broadway pipeline for a Kafka producer.

  Additional configuration is determined by a config entry for the `:credits` application under the key `:broadway`.
  """
  def start_link(opts) do
    config = Application.fetch_env!(:credits, :broadway)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Events.Kafka, opts},
        concurrency: config[:producer][:concurrency]
      ],
      processors: config[:processors]
    )
  end

  @doc """
  Returns `true` if the message data contains a valid user id under the `user_id` key.

  In this case, "valid" means it can be cast as an `Ecto.UUID` type.
  """
  def valid_user_id?(%{"user_id" => nil}), do: false
  def valid_user_id?(%{"user_id" => user_id}), do: Ecto.UUID.cast(user_id) != :error
  def valid_user_id?(_), do: false

  # Extract the event topic and data from the message before processing.
  def handle_message(_, %Message{data: %{topic: topic, body: data}} = msg, _) do
    if valid_user_id?(data) do
      case process_message(topic, data) do
        :ok ->
          msg

        :ignore ->
          # This isn't actually an error, but we mark it as failed so we can NACK the message.
          Logger.info("User process pending startup", topic: topic, message: msg)
          Message.failed(msg, "User process is pending startup")

        result ->
          # Unknown problem, should never happen, log an error.
          Logger.error("Unexpected result from message processing", topic: topic, message: msg, result: result)
          Message.failed(msg, "Unexpected result from message processing")
      end
    else
      Logger.error("Ignoring message with invalid user_id", topic: topic, message: msg)
      msg
    end
  end

  # Handle job completion events.
  def process_message("jobs.complete", %{"user_id" => user_id} = job) do
    complete_job(user_id, job)
  end

  # Handles credit entitlement events.
  def process_message(
        "entitlements.credits",
        %{
          "user_id" => user_id,
          "entitlements" => entitlements
        } = data
      ) do
    grant_entitlements(user_id, Entitlements.convert(entitlements))
  end

  # If we get here, this isn't a message we care to handle, just no-op and ack it.
  def process_message(topic, event) do
    Logger.debug("Ignoring message", topic: topic, event: event)
  end

  @doc """
  Potentially sends a job completion event to the user process.
  """
  def complete_job(user_id, %{"id" => job_id, "charge_credits" => false} = job) do
    Logger.debug("Job flagged to not charge credits",
      user_id: user_id,
      job_id: job_id,
      job: job
    )
  end

  def complete_job(user_id, %{"id" => job_id} = job) do
    # If the job didn't already have a calculated cost we would put it here.
    # e.g. job = Map.put_new_lazy(job, "cost", fn -> calculate_cost(job) end)
    User.complete(user_id, job)
  end

  @doc """
  Grants credits to a user through a set of entitlements.
  """
  def grant_entitlements(user_id, grants) when map_size(grants) == 0 do
    Logger.debug("No entitlements to grant", user_id: user_id, metadata: metadata)
  end

  def grant_entitlements(user_id, grants) do
    User.grant(user_id, grants)
  end
end
