defmodule Credits.Schema.ExpiringCredit do
  use Ecto.Schema

  alias Schema.MongoTimestamp

  @derive {Jason.Encoder,
           only: [
             :user_id,
             :initial,
             :amount,
             :created_at,
             :expires_at,
             :note
           ]}

  @type t :: %__MODULE__{
          user_id: String.t(),
          initial: integer(),
          amount: integer(),
          created_at: DateTime.t(),
          expires_at: DateTime.t(),
          note: String.t()
        }

  @primary_key false
  schema "expiring_credits" do
    field(:user_id, :string)

    # Metadata about the credit.
    field(:initial, :integer)
    field(:amount, :integer)
    # We use a custom type to handle weird mongo typing to get this into the format we expect of timestamps in a Postgres database.
    field(:created_at, MongoTimestamp)
    field(:expires_at, MongoTimestamp)
    field(:note, :string)
  end
end
