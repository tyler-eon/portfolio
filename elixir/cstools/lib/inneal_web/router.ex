defmodule InnealWeb.Router do
  use InnealWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {InnealWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :auth do
    plug :browser

    plug Guardian.Plug.Pipeline,
      module: Inneal.Guardian,
      error_handler: InnealWeb.Guardian.ErrorHandler

    plug Guardian.Plug.VerifyHeader
    plug Guardian.Plug.VerifySession, refresh_from_cookie: true
    plug Guardian.Plug.EnsureAuthenticated
    plug Guardian.Plug.LoadResource, allow_blank: false
  end

  pipeline :insecure_api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session

    plug Guardian.Plug.Pipeline,
      module: Inneal.Guardian,
      error_handler: InnealWeb.Guardian.ErrorHandler.JSON

    plug Guardian.Plug.VerifyHeader
    plug Guardian.Plug.VerifySession, refresh_from_cookie: true
    plug Guardian.Plug.EnsureAuthenticated
    plug Guardian.Plug.LoadResource, allow_blank: false
  end

  scope "/", InnealWeb do
    pipe_through :browser

    get "/", PageController, :index
    get "/healthz", PageController, :health
    get "/logout", PageController, :logout
  end

  scope "/app", InnealWeb do
    pipe_through :auth

    get "/", AppController, :index
    post "/search", AppController, :search
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:inneal, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: InnealWeb.Telemetry
    end
  end
end
