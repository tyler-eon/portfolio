defmodule Inneal.FirebaseKeyServer do
  @moduledoc """
  Verifying Firebase ID tokens requires a public key. This simple GenServer caches the public key until it expires and then fetches the new public key.

  The public key is fetched from https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com and stored for an amount of time based on the `max-age` value in the `Cache-Control` response header.
  """

  @public_key_url "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {
      :ok,
      %{
        keys: %{},
        expiry: nil
      },
      {:continue, :init}
    }
  end

  @doc """
  Returns a public key for the given ID. If the key id is not valid, nil is returned.

  This will check whether the current keys are stale and fetch new keys if necessary.
  """
  def key(id), do: GenServer.call(__MODULE__, {:key, id})

  @doc """
  Returns a JWK for the given key ID. If the key id is not valid, nil is returned.

  This will check whether the current keys are stale and fetch new keys if necessary.
  """
  def jwk(kid), do: GenServer.call(__MODULE__, {:jwk, kid})

  @doc """
  Returns a list of all public keys currently stored by the agent.

  NOTE: This is not intended for normal production use and should only be used for introspection purposes. No staleness check is performed and the keys returned by this function are not guaranteed to be valid.
  """
  def keys(), do: GenServer.call(__MODULE__, :keys)

  @doc """
  Attempts to refresh the list of public keys. If `force` is false, new keys will only be fetched if the current keys are stale. Otherwise, new keys will be fetched regardless of staleness.
  """
  def refresh(force \\ false), do: GenServer.cast(__MODULE__, {:refresh, force})

  def handle_continue(:init, state), do: {:noreply, refresh_keys(state, true)}

  def handle_call({:key, id}, _from, state) do
    state = refresh_keys(state, false)
    {:reply, Map.get(state.keys, id), state}
  end

  def handle_call({:jwk, kid}, _from, state) do
    state = refresh_keys(state, false)

    case state.keys |> JOSE.JWK.from_firebase() |> Map.fetch!(kid) do
      nil -> {:reply, nil, state}
      jwk -> {:reply, jwk, state}
    end
  end

  def handle_call(:keys, _from, state) do
    {:reply, state.keys, state}
  end

  def handle_cast({:refresh, force}, state) do
    {:noreply, refresh_keys(state, force)}
  end

  defp refresh_keys(state, force) do
    if force || is_stale?(state) do
      fetch_key_data()
    else
      state
    end
  end

  @doc """
  Fetches Firebase public keys from the necessary endpoint and converts it into a map of the form:

  ```
  %{
    "keys" => %{
      "key_id" => "public_key",
      ...
    }
    "expiry" => ~U[20xx-mm-dd 00:00:00Z],
  }
  ```

  The `expiry` value is the absolute time when the keys should be considered stale. If the value is nil, no expiry could be inferred from the response headers.
  """
  def fetch_key_data() do
    case :hackney.get(@public_key_url, [], "", []) do
      {:ok, 200, headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        keys = Jason.decode!(body)
        expiry = parse_expiry(headers)
        %{keys: keys, expiry: expiry}

      _ ->
        %{keys: %{}, expiry: nil}
    end
  end

  @doc """
  Parses the `Cache-Control` header and returns the expiry date based on the `max-age` value.

  If no `Cache-Control` header is found, or it does not contain a `max-age` value, this returns nil.
  """
  def parse_expiry(headers) do
    case List.keyfind(headers, "Cache-Control", 0) do
      {"Cache-Control", value} ->
        case Regex.run(~r/max-age=(?<max_age>\d+)/, value) do
          [_, max_age] -> DateTime.add(DateTime.utc_now(), String.to_integer(max_age), :second)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns true if the `expiry` key is either nil or set to a time in the past, implying that the keys are stale.
  """
  def is_stale?(%{expiry: nil}), do: true
  def is_stale?(%{expiry: expiry}), do: expiry <= DateTime.utc_now()
end
