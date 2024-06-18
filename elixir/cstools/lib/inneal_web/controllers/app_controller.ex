defmodule InnealWeb.AppController do
  use InnealWeb, :controller

  plug InnealWeb.Plug.Bouncer,
       [namespace: "default", object: "app", relation: "read"]
       when action in [:index, :search]

  def index(conn, _params) do
    render(conn, :index)
  end

  def search(conn, %{"provider" => provider, "user_id" => uid}) do
    provider = String.trim(provider)
    uid = String.trim(uid)

    user_id = get_user_id_from_provider(provider, uid)

    redirect(conn, to: "/users/#{user_id}")
  end
end
