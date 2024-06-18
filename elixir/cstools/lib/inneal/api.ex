defmodule Inneal.API do
  @moduledoc """
  Provides a context for interacting with the billing API using an application-configured API key for authentication.
  """

  @api_key Application.compile_env!(:inneal, :api_key)

  @doc """
  Returns the billing information for a customer given their user id.
  """
  def get_billing(uid), do: fetch_with_auth("billing/api/endpoint")

  @doc """
  Fetches a list of all plans currently in use.
  """
  def get_plans(), do: fetch_with_auth("products/plans/api/endpoint")

  @doc """
  Performs an HTTP request using the application-configured API key.

  When `method_or_body` is an atom, it is assumed that an HTTP method has been given and that the body of the request should be empty.

  When `method_or_body` is a binary string or map, it is assumed that the HTTP method should default to `:post` since there's a request body to send.

  When `method_or_body` is omitted, this defaults to a `:get` request with an empty request body.
  """
  @spec fetch_with_auth(String.t(), atom() | String.t() | map()) :: {:ok | :not_found | :error, String.t()}
  def fetch_with_auth(path, method_or_body \\ :get)

  def fetch_with_auth(path, method) when is_atom(method), do: fetch_with_auth(path, method, "")
  def fetch_with_auth(path, body) when is_binary(body), do: fetch_with_auth(path, :post, body)
  def fetch_with_auth(path, body) when is_map(body), do: fetch_with_auth(path, :post, Jason.encode!(body))

  @doc """
  Performs an HTTP request using the application-configured API key.
  """
  @spec fetch_with_auth(String.t(), atom(), String.t()) :: {:ok | :not_found | :error, String.t()}
  def fetch_with_auth(path, method, body) do
    method
    |> :hackney.request(
      path,
      [{"Authorization", "Bearer #{@api_key}"}],
      body,
      []
    )
    |> parse_response()
  end

  defp parse_response({:ok, status, _headers, ref}) do
    {:ok, body} = :hackney.body(ref)
    parse_response(status, Jason.decode!(body))
  end

  defp parse_response(200, body), do: {:ok, body}
  defp parse_response(404, body), do: {:not_found, body}
  defp parse_response(_, body),   do: {:error, body}
end
