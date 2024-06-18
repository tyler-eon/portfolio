defmodule InnealWeb.UserLive.StripeComponent do
  use InnealWeb, :live_component

  alias InnealWeb.Components.Stripe

  @impl true
  def render(assigns) do
    ~H"""
    <div id="stripe-subscription" class="flex-1 mx-2">
      <h2 class="title">Stripe Details</h2>
      <table class="table-auto with-borders">
        <tr>
          <td>Customer</td>
          <td>
            <a href={Stripe.customer_url(@stripe["customer_id"])} traget="_blank">
              <%= @subscription[:stripe]["customer_id"] %>
            </a>
          </td>
        </tr>
        <tr>
          <td>Subscription</td>
          <td>
            <a href={Stripe.subscription_url(@stripe["subscription_id"])} traget="_blank">
              <%= @subscription[:stripe]["subscription_id"] %>
            </a>
          </td>
        </tr>
        <tr>
          <td>Self-Service Link</td>
          <td>
            <%= if @stripe[:self_service_url] do %>
              <a href={@stripe[:self_service_url]} traget="_blank">
                <%= @stripe[:self_service_url] %>
              </a>
            <% else %>
              <button class="confirm" phx-click="generate_self_service_url">Generate</button>
            <% end %>
          </td>
        </tr>
      </table>
    </div>
    """
  end
end
