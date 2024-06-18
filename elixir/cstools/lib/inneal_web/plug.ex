defmodule InnealWeb.Plug.Bouncer do
  @moduledoc """
  Allows Pluggable authorization checks via Inneal.Bouncer.

  ## Examples

      defmodule SubscriptionController do
        use InnealWeb, :controller

        plug InnealWeb.Plug.Bouncer, [namespace: "default", object: "subscription", relation: "read"] when action in [:show]

        def show(conn, _params) do
          render(conn, :show)
        end
      end

  You can even stack multiple checks if a given action requires multiple permissions:

      defmodule SubscriptionController do
        use InnealWeb, :controller

        plug InnealWeb.Plug.Bouncer, [namespace: "default", object: "subscription", relation: "read"] when action in [:show]
        plug InnealWeb.Plug.Bouncer, [namespace: "stripe", object: "subscription", relation: "read"] when action in [:show]

        def show(conn, _params) do
          render(conn, :show)
        end
      end

  Here we have two relations, `default#subscription:read` and `stripe#subscription:read`, that must *both* be valid for a given user in order for `SubscriptionController.show/2` to be executed.

  ## Options

  The following options are *required*:

  - `namespace`
  - `object`
  - `relation`

  The following options are *optional*:

  - `check_domain` (default: `true`)
  - `redirect_to` (default: `"/app"`)

  ### `redirect_to`

  This is where the user will be redirected to if they fail a permission check.
  """

  import Phoenix.Controller
  import Plug.Conn

  require Logger

  def init(opts) do
    %{
      namespace: Keyword.fetch!(opts, :namespace),
      object: Keyword.fetch!(opts, :object),
      relation: Keyword.fetch!(opts, :relation),
      redirect_to: Keyword.get(opts, :redirect_to, "/app")
    }
  end

  def call(conn, %{redirect_to: redirect_to}=opts) do
    if conn
    |> InnealWeb.Guardian.current_user_id()
    |> check_user(opts) do
      conn
    else
      permission_failure(conn, redirect_to)
    end
  end

  @doc """
  This function is intended to be called similarly to `call/2` but using a `socket` from a LiveView instead of a `Plug.Conn`.

  This should be used on a hook such as `on_mount` as the return value is either `{:cont, socket}` on a success or `{:halt, socket}` on a failure. On a failure, the returned socket will already have an appropriate redirect assigned to it as specified by the `redirect_to` option.
  """
  def live_view(socket, opts) when is_list(opts), do: live_view(socket, init(opts))
  def live_view(%{assigns: %{current_user: nil}}=socket, %{redirect_to: redirect_to}) do
    {:halt, Phoenix.LiveView.redirect(socket, to: redirect_to)}
  end
  def live_view(%{assigns: %{current_user: %{"id" => id}}}=socket, %{redirect_to: redirect_to}=opts) do
    if check_user(email, opts) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: redirect_to)}
    end
  end

  @doc """
  Given a user's unique id, checks whether they have permission to a given resource via the specified relationship.

  If a full map of options is not given then a keyword list must be used to initialize the options map. For example:

      check_user(id, [namespace: "default", object: "subscription", relation: "read"])

  The keys `namespace`, `object`, and `relation` are required. The key `check_domain` is optional.

  Since this returns a true/false value, `redirect_to` is not used here and will be ignored if present.
  """
  def check_user(id, %{
    namespace: ns,
    object: obj,
    relation: rel,
    check_domain: check_domain
  }) do
    Logger.debug("Checking user #{id} for #{ns}##{obj}:#{rel}")
    Inneal.Bouncer.check(ns, obj, rel, id)
  end

  def check_user(id, opts), do: check_user(id, init(opts))

  def permission_failure(conn, redirect_to) do
    conn
    |> put_flash(:error, "You do not have permission to view that resource.")
    |> redirect(to: redirect_to)
    |> halt()
  end
end
