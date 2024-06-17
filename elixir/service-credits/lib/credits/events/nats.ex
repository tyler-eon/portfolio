defmodule Events.Nats do
  @moduledoc """
  This module is a GenStage implementation responsible for subscribing to a set of topics and forwarding received messages to Broadway. It assumes that a `Gnat.ConnectionSupervisor` instance is running separately.

  This module is modeled after the subscription supervisor from the official `gnat` library, except there was no easy way to integrate it with Broadway at the time this was written. Therefore it's almost exactly the same code as the official library has with two major differences:

  1. It uses GenStage instead of GenServer.
  2. It incorporates Broadway functionality directly.

  If I were to use NATS in the future there is now an official module in an updated version of the library that allows Broadway to be easily integrated with a pull-based Jetstream consumer. It's a shame this didn't exist when I was originally building the library as a pull-based consumer would have solved a lot of pain I experienced early on trying to solve a NATS-related issue stemming from our push-based consumer configuration.
  """

  use GenStage

  require Logger

  alias Broadway.Message

  @doc """
  Start the NATS message producer process.

  The `opts` argument is expected to be a keyword list and must contain at least the following keys:

  - `:gnat` - The name of the Gnat connection process to use.
  - `:subscriptions` - A list of topics to subscribe to.

  Each subscription item must be of the type `String.t | {String.t, String.t}`. If a tuple is provided, the first element is a topic name and the second element is a queue group name.

  You may also optionally pass in `:name` to set the name of the process.
  """
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil ->
        GenStage.start_link(__MODULE__, opts)

      name ->
        GenStage.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Each message contains their own `reply_to` reference which is a specialized subject unique to a single message which, when it receives any message (even an empty string), acts as an ACK for the original message.

  There is no explicit NACK operation for our current "push" consumer type, which just streams in messages as fast as possible. Therefore we simply ignore any failed messages and the ACK timeout will determine when the message is retried.
  """
  def ack(pid, successful, _failed) do
    Enum.each(successful, fn
      %Message{data: %{reply_to: reply_to}} ->
        Gnat.pub(pid, reply_to, "")

      msg ->
        Logger.warning("Received a message to ACK without a reply-to ref", message: msg)
    end)
  end

  @doc """
  Convert the contents a NATS message into a `Broadway.Message` struct.

  This function assumes that the NATS message body is a JSON string. If the message body is not a JSON string, this function will raise an error.

  In order to batch-ack messages when possible, this function will use the PID of the NATS producer as the ack reference and then each individual message will contain a `reply_to` key to be used for acknowledging the message. Using the PID of the NATS producer ensures that if we somehow process messages from multiple NATS producers that we can group messages by producer when we acknowledge them.
  """
  def convert(pid, %{topic: topic, body: body} = msg) do
    data = %{topic: topic, body: Jason.decode!(body)}

    case Map.get(msg, :reply_to, nil) do
      nil ->
        %Message{
          data: data,
          acknowledger: Broadway.NoopAcknowledger.init()
        }

      reply_to ->
        %Message{
          data: Map.put(data, :reply_to, reply_to),
          acknowledger: {__MODULE__, pid, nil}
        }
    end
  end

  @impl GenStage
  def init(opts) do
    Logger.info("Starting NATS message producer...")
    Process.flag(:trap_exit, true)

    # Defer the actual connection process until after the GenStage module is started and registered.
    case Keyword.get(opts, :delay_connect) do
      nil ->
        Process.send(self(), :connect, [])

      time ->
        Process.send_after(self(), :connect, time)
    end

    {:producer,
     %{
       gnat: Keyword.fetch!(opts, :gnat),
       gnat_pid: nil,
       subscriptions: Keyword.fetch!(opts, :subscriptions),
       sids: []
     }}
  end

  @impl GenStage
  def handle_info(:connect, %{gnat: gnat, subscriptions: subscriptions} = state) do
    Logger.debug("Checking NATS connection...")

    case Process.whereis(gnat) do
      nil ->
        Logger.error("NATS connection not ready. Retrying in 1 second...")
        Process.send_after(self(), :connect, 1_000)
        {:noreply, [], state}

      pid ->
        Logger.info("NATS connection ready. Subscribing to topics...")

        # We don't need the monitor reference, we just need to receive the `:DOWN` event if the Gnat connection goes down.
        _ref = Process.monitor(pid)

        # Subscribe to the configured topics.
        sids =
          Enum.map(subscriptions, fn sub ->
            {subject, opts} =
              case sub do
                {name, queue_group} ->
                  {name, [queue_group: queue_group]}

                name ->
                  {name, []}
              end

            Logger.debug("Subscribing to NATS topic.", topic: subject, opts: opts)
            {:ok, sid} = Gnat.sub(pid, self(), subject, opts)
            sid
          end)

        {:noreply, [], %{state | gnat_pid: pid, sids: sids}}
    end
  end

  def handle_info({:DOWN, _ref, :process, gnat_pid, _reason}, %{gnat_pid: gnat_pid} = state) do
    Logger.error("NATS connection down. Reconnecting in 1 second...")
    Process.send_after(self(), :connect, 1_000)
    {:noreply, [], %{state | gnat_pid: nil}}
  end

  def handle_info({:msg, msg}, state) do
    # We've received a message from the gnat connection.
    message = convert(state.gnat_pid, msg)
    Logger.debug("NATS message received", message: message)
    {:noreply, [message], state}
  end

  def handle_info(_msg, state), do: {:noreply, [], state}

  @impl GenStage
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl GenStage
  def terminate(:shutdown, %{gnat_pid: gnat_pid, sids: sids} = state) do
    Logger.warning("Shutdown event received, terminating NATS message producer...")
    Enum.each(sids, fn sid -> :ok = Gnat.unsub(gnat_pid, sid) end)
    Process.sleep(500)
    process_final_messages(state)
  end

  def terminate(_, _state), do: :ok

  @doc """
  It's possible for messages to be the in queue when the consumer is terminated. This function will process each remaining message in the queue before allowing the process to terminate.
  """
  def process_final_messages(state) do
    receive do
      info ->
        handle_info(info, state)
        process_final_messages(state)
    after
      0 ->
        :done
    end
  end
end
