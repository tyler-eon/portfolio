defmodule InnealWeb.Guardian do
  def current_email(conn) do
    case conn
         |> Inneal.Guardian.Plug.current_resource()
         |> Map.get("email") do
      nil ->
        conn
        |> Inneal.Guardian.Plug.current_claims()
        |> Map.get("email")

      email ->
        email
    end
  end
end

defmodule InnealWeb.Guardian.ErrorHandler do
  use InnealWeb, :controller

  require Logger

  def auth_error(conn, err, _opts) do
    Logger.warning("Auth error: #{inspect(err)}")
    redirect(conn, to: "/")
  end
end

defmodule InnealWeb.Guardian.ErrorHandler.JSON do
  use InnealWeb, :controller

  require Logger

  def auth_error(conn, err, _opts) do
    Logger.warning("Auth error: #{inspect(err)}")
    json(conn, %{error: "unauthorized", reason: err})
  end
end

defmodule InnealWeb.Live.Guardian do
  import Phoenix.Component
  import Phoenix.LiveView

  require Logger

  def on_mount(:default, _params, session, socket) do
    token_key = Guardian.Plug.Keys.token_key(:default)
    case Map.get(session, Atom.to_string(token_key)) do
      nil ->
        Logger.error("No auth token found in live session")
        {:halt, redirect(socket, to: "/app")}

      token ->
        case Inneal.Guardian.decode_and_verify(token) do
          {:ok, claims} ->
            {:cont, assign(socket, :current_user, claims)}

          {:error, reason} ->
            Logger.error("Invalid auth token found in live session (#{reason})")
            {:halt, redirect(socket, to: "/app")}
        end
    end
  end
end
