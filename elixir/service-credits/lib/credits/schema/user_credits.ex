defmodule Credits.Schema.UserCredits do
  use Ecto.Schema

  alias Credits.Schema.ExpiringCredit

  @derive {Jason.Encoder,
           only: [
             :user_id,
             :trial,
             :permanent,
             :expiring
           ]}

  @type t :: %__MODULE__{
          user_id: String.t(),
          trial: integer(),
          permanent: integer(),
          expiring: [ExpiringCredit.t()]
        }

  @primary_key {:user_id, :binary_id, []}
  schema "user_credits" do
    # Common credit types.
    field(:trial, :integer, default: 0)
    field(:permanent, :integer, default: 0)

    # Expiring credits have additional metadata, so we store those separately.
    embeds_many(:expiring, ExpiringCredit, on_replace: :delete)
  end
end
