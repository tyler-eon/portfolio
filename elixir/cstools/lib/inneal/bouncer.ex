defmodule Inneal.Bouncer do
  @moduledoc """
  Manages permission checks.

  Currently uses Ory Keto, an open-source implementation of Google's Zanzibar. The basic concept is:

  You have a relation tuple consisting of a namespace, an object, a relation, and a subject. The namespace just helps with allowing multiple objects to be named similarly while still existing as separate relations. The subject can be either a unique identifier or a "subject set", which is fancy speak for a reference to some other relation. Subject sets effectively allow you to state "this relation inherits permissions from this other relation".

  For things where you have actual "objects", in the sense that you have files or other discrete entities, the concept is relatively straightforward. For the following example, we will make things less straightforward by assuming we are building an API permissions system.

  ## Example

  Let's assume the following:

  1. We have data stored internally to our system and so all aspects of that system will be in the namespace "internal".
  2. We have data stored externally in Stripe and so all aspects of that system will be in the namespace "stripe".
  3. We want both individual users *and their email domains* to be subject identifiers.
  4. We want to have groups of users that can be referenced as subject sets.
  5. The "object" of a relation is the part of the system that you are interacting with.
  6. The "relation" is the actual permission a user needs to be able to interact with "object".

  Right off the bat, let's create a group `billing-support`. We want anyone that works for our external support company to be in this group, so we'll add a special user to this group, `@support-staff.com`. The relation to add members to this group would look like:

  ```elixir
  %{
    namespace: "groups",
    object: "billing-support",
    relation: "member",
    subject_id: "@support-staff.com",
  }
  ```

  If we had other individuals or email domains that required membership to this group, we'd just do the same thing with different `subject_id` values.

  Now let's create viewing permissions to look at a customer's subscription data.

  ```elixir
  %{
    namespace: "internal",
    object: "subscriptions",
    relation: "viewer",
    subject_set: %{
      namespace: "groups",
      object: "billing-support",
      relation: "member",
    },
  }

  %{
    namespace: "stripe",
    object: "subscriptions",
    relation: "viewer",
    subject_set: %{
      namespace: "groups",
      object: "billing-support",
      relation: "member",
    },
  }
  ```

  Because we have both internal and external subscription data, we have two relations separated by `namespace`. Here we are using `subject_set` to state "anyone that has the `groups:billing-support#member` relation can view subscription data".

  However, Keto itself doesn't understand concepts like "this user *or their email domain*". It only understands the relation tuple. Therefore, it is up to us to program any potential hierarchy into the permission checking logic. That means our code to check permissions might do something like:

  ```elixir
  user = get_user()
  domain = get_domain(user)
  case user_or_domain_check("internal", "subscriptions", "viewer", user, domain) do
    false -> false
    true  -> user_or_domain_check("stripe", "subscriptions", "viewer", user, domain)
  end
  ```

  Additionally, we can build up hierarchical relations. Let's say we also have an `editor` relation; in theory, an editor should be capable of viewing data as well, otherwise how could they edit it? So let's add a hierarchical relation:

  ```elixir
  %{
    namespace: "internal",
    object: "subscriptions",
    relation: "viewer",
    subject_set: %{
      namespace: "internal",
      object: "subscriptions",
      relation: "editor",
    },
  }

  %{
    namespace: "stripe",
    object: "subscriptions",
    relation: "viewer",
    subject_set: %{
      namespace: "stripe",
      object: "subscriptions",
      relation: "editor",
    },
  }
  ```

  Notice that we're adding a relation to the `viewer` permission. This is telling the system "anyone who is an editor should also have viewer access". Now let's assume we have an actual group called "admins" which should have editor permissions to everything.

  ```elixir
  %{
    namespace: "internal",
    object: "subscriptions",
    relation: "editor",
    subject_set: %{
      namespace: "groups",
      object: "admins",
      relation: "member",
    },
  }

  %{
    namespace: "stripe",
    object: "subscriptions",
    relation: "editor",
    subject_set: %{
      namespace: "groups",
      object: "admins",
      relation: "member",
    },
  }
  ```

  So now any subjects that are associated with `groups:admins#member` will have `internal:subscriptions#editor` and `stripe:subscriptions#editor` relations. And because we have hierarchical relations, they will also have `internal:subscriptions#viewer` and `stripe:subscriptions#viewer` relations. To put this in perspective, the relation tree would look something like:


  ```
  internal:subscriptions#viewer
  | -> groups:billing-support#member
  | -> internal:subscriptions#editor
  |    | -> groups:admins#member

  stripe:subscriptions#viewer
  | -> groups:billing-support#member
  | -> stripe:subscriptions#editor
  |    | -> groups:admins#member
  ```

  In this system the "leafs" are the subjects which will gain access to everything above them. So subjects associated with `groups:billing-support#member` will only have access to the permissions above that group, `(internal|stripe):subscriptions#viewer`. However, subjects associated with `groups:admins#member` will have access to everything: `(internal|stripe):subscriptions#editor` *and* `(internal|stripe):subscriptions#viewer`.

  Because you are intended to use subject sets to build up hierarchical relations, you should not be setting many individual subject ids on relations directly, instead preferring to use subject sets either to build upon existing permissions (like editor getting viewer permissions) or to reference groups.
  """

  @doc """
  Converts relationship attributes to a tuple.

  In Keto, a tuple is really just a map with the keys `namespace`, `object`, `relation`, and either `subject_id` or `subject_set`.
  """
  def relation_tuple(namespace, object, relation, subject_id) when is_binary(subject_id) do
    %{
      namespace: namespace,
      object: object,
      relation: relation,
      subject_id: subject_id,
    }
  end
  def relation_tuple(namespace, object, relation, subject_set) when is_map(subject_set) do
    %{
      namespace: namespace,
      object: object,
      relation: relation,
      subject_set: subject_set,
    }
  end

  @doc """
  Sets an allowed permission for a subject or subject set.
  """
  def allow(namespace, object, relation, subject_or_set) do
    res =
      namespace
      |> relation_tuple(object, relation, subject_or_set)
      |> allow_permission()

    case res do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Removes a permission for a subject or subject set.
  """
  def revoke(namespace, object, relation, subject_or_set) do
    res =
      namespace
      |> relation_tuple(object, relation, subject_or_set)
      |> revoke_permission()

    case res do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Checks if the given relation tuple is allowed.

  Although you may pass in a subject set here, it is not recommended. If you are using subject sets to correctly build hierarchical and referential relations, you should almost always be passing in a subject id for permission checks. See the module documentation for information on how to build hierarchical and referential relations using subject sets.
  """
  def check(namespace, object, relation, subject_or_set) do
    res =
      namespace
      |> relation_tuple(object, relation, subject_or_set)
      |> check_permission()

    case res do
      {:ok, body} -> body["allowed"]
      _ -> false
    end
  end

  @doc """
  Lists all permissions matching a given query. If no query parameters are given, this returns all permissions.

  Responses are paginated using a `next_page_token` field. If a response has that parameter, simply pass it as a query parameter to the next request and you will get the next set of results. If that parameter is not present or an empty string, there are no more results to paginate.
  """
  def list(query \\ %{}) do
    case :get
         |> send_read_request("/relation-tuples", query)
         |> parse_response() do
      {:ok, res} -> res
      _ -> nil
    end
  end

  @doc """
  Retrieve a list of all valid namespaces.

  Namespaces are the one thing that must be configured when the Keto server is started, so using any namespaces not pre-configured at startup will result in an error when used elsewhere. You may use this function to validate the namespaces that are valid for use.
  """
  def namespaces() do
    case :get
         |> send_read_request("/namespaces", nil)
         |> parse_response() do
      {:ok, %{"namespaces" => ns}} -> Enum.map(ns, & &1["name"])
      _ -> nil
    end
  end

  # private

  defp allow_permission(tuple) do
    :put
    |> send_write_request("/admin/relation-tuples", tuple)
    |> parse_response()
  end

  defp revoke_permission(tuple) do
    :delete
    |> send_write_request("/admin/relation-tuples", tuple)
    |> parse_response()
  end

  defp check_permission(tuple) do
    :post
    |> send_read_request("/relation-tuples/check", tuple)
    |> parse_response()
  end

  defp send_read_request(method, path, payload) do
    {url, body} =
      prepare_parameters(method, System.get_env("KETO_READ", "http://keto:4466"), path, payload)

    :hackney.request(
      method,
      url,
      [{"Content-Type", "application/json"}],
      body,
      []
    )
  end

  defp send_write_request(method, path, payload) do
    {url, body} =
      prepare_parameters(method, System.get_env("KETO_WRITE", "http://keto:4467"), path, payload)

    :hackney.request(
      method,
      url,
      [{"Content-Type", "application/json"}],
      body,
      []
    )
  end

  defp prepare_parameters(method, base, path, payload) when method in [:get, :delete] do
    payload =
      case payload do
        nil ->
          []

        "" ->
          []

        payload ->
          case Map.get(payload, :subject_set) do
            nil ->
              payload

            %{
              namespace: ns,
              object: obj,
              relation: rel
            } ->
              payload
              |> Map.put("subject_set.namespace", ns)
              |> Map.put("subject_set.object", obj)
              |> Map.put("subject_set.relation", rel)
              |> Map.delete(:subject_set)
          end
      end

    {:hackney_url.make_url(base, path, Enum.into(payload, [])), ""}
  end

  defp prepare_parameters(_method, base, path, payload) do
    {base <> path, Jason.encode!(payload)}
  end

  defp parse_response({:ok, status, _headers, ref}) do
    case status do
      # Canonically, a 204 response *must* be empty, so we always ignore any potential body that might have been accidentally set.
      204 ->
        {:ok, :ok}

      _ ->
        {:ok, body} = :hackney.body(ref)
        parse_response(status, Jason.decode!(body))
    end
  end

  defp parse_response(200, body), do: {:ok, body}
  defp parse_response(201, body), do: {:ok, body}
  defp parse_response(403, body), do: {:forbidden, body}
  defp parse_response(404, body), do: {:not_found, body}
  defp parse_response(_, body),   do: {:error, body}
end
