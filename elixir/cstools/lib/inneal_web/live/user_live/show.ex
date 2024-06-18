defmodule InnealWeb.UserLive.Show do
  use InnealWeb, :live_view

  require Logger

  import Ecto.Query

  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(params, session, socket) do
    case InnealWeb.Live.Guardian.on_mount(:default, params, session, socket) do
      {:cont, socket} ->
        case InnealWeb.Plug.Bouncer.live_view(socket, [namespace: "default", object: "app", relation: "read"]) do
          {:halt, socket} ->
            {:ok, socket}

          {:cont, socket} ->
            {:ok, finish_mount(params, session, socket)}
        end

      {:halt, socket} ->
        {:ok, socket}
    end
  end

  def finish_mount(%{"user_id" => user_id}, _session, socket) do
    Logger.info("Mounting user #{user_id}")

    case get_user(user_id) do
      {:error, :not_found} ->
        socket
        |> put_flash(:error, "User not found")
        |> redirect(to: "/app")

      {:error, err} ->
        socket
        |> put_flash(:error, "Unknown error: #{inspect(err)}")
        |> redirect(to: "/app")

      user ->
        connect_params = get_connect_params(socket) || %{}
        last_allocation = user[:subscription][:allocated]

        # Breaking up the user like this lets us access different attributes
        # of a user more easily and only updates the parts that need updating.
        socket
        |> assign(:locale, Map.get(connect_params, "locale", "en-US"))
        |> assign(:timezone, Map.get(connect_params, "timezone", "Etc/UTC"))
        |> assign(:user, %{id: user_id})
        # A mix of additional `assign/3` and `start_async/3` functions.
    end
  end

  @impl true
  def handle_params(_params, _session, socket), do: {:noreply, socket}

  @impl true
  def handle_event("generate_self_service_url", _params, socket) do
    case InnealWeb.Plug.Bouncer.live_view(socket, [namespace: "stripe", object: "subscription", relation: "read"]) do
      {:cont, _} ->
        user_id = socket.assigns.user.id
        {:noreply, start_async(socket, :generate_self_service_url, fn ->
          Inneal.API.get_stripe_portal(user_id, "https://my.domain")
        end)}

      {:halt, _} ->
        {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("link_stripe", _params, socket) do
    case InnealWeb.Plug.Bouncer.live_view(socket, [namespace: "stripe", object: "subscription", relation: "write"]) do
      {:cont, _} ->
        user_id = socket.assigns.user.id
        {:ok, %Stripe.SearchResult{data: res}} =
          Stripe.Subscription.search(%{
            query: "status:'active' and metadata['user_id']:'#{user_id}'"
          })

        case res do
          [] ->
            {:noreply, put_flash(socket, :error, "No active subscription found")}

          [sub] ->
            Inneal.Mongo.Repo.sync_stripe_to_mongo(user_id, sub)
            user = get_user(user_id)
            socket = socket
            |> put_flash(:info, "Subscription synced successfully.")
            # Use `assign/3` to dynamically update the parts of the page that contain related data.
            {:noreply, socket}

          [sub | _] ->
            Inneal.Mongo.Repo.sync_stripe_to_mongo(user_id, sub)
            user = get_user(user_id)
            socket = socket
            |> put_flash(:info, "Multiple matching Stripe accounts found, subscription synced to the most recently created.")
            # Use `assign/3` to dynamically update the parts of the page that contain related data.
            {:noreply, socket}
        end

      {:halt, _} ->
        {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  @impl true
  def handle_async(:generate_self_service_url, {:ok, {:ok, %{"url" => url}}}, socket) do
    stripe = socket.assigns.stripe
    {:noreply, assign(socket, :stripe, %{stripe | self_service_url: url})}
  end

  # Success for simple patterns.
  def handle_async(var, {:ok, {:ok, result}}, socket) do
    {:noreply, assign(socket, var, AsyncResult.ok(result))}
  end

  # Generic DBConnection error handling.
  def handle_async(var, {:exit, {%DBConnection.ConnectionError{}, _}}, socket) do
    {:noreply, assign(socket, var, "Could not load #{var} - database connection error")}
  end

  # Failure for simple patterns.
  def handle_async(var, {:ok, {:error, error}}, socket) do
    Logger.error("Error loading #{var}: #{inspect(error)}")
    socket = socket
    |> put_flash(:error, error)
    |> assign(var, AsyncResult.failed(AsyncResult.loading(), error))
    {:noreply, socket}
  end
end
