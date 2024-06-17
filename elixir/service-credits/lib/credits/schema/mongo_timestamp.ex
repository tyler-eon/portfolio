defmodule Schema.MongoTimestamp do
  @moduledoc """
  A custom Ecto type specific to our MongoDB schema, where we store timestamps as integers representing number of milliseconds (or seconds) since the unix epoch.

  The schema stores a DateTime struct but reads from/writes to the database as an appropriate integer representation.
  """
  use Ecto.Type

  @doc """
  The underlying *Ecto* type that we are converting to/from.
  """
  @impl Ecto.Type
  def type, do: :utc_datetime_usec

  @doc """
  Casts a value to a DateTime struct. Values can be:

  - DateTime structs.
  - ISO8601 formatted strings.
  - Unix integer timestamps (in seconds or milliseconds).
  """
  @impl Ecto.Type
  def cast(%DateTime{} = value), do: value

  def cast(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      error -> error
    end
  end

  def cast(value) when is_integer(value) do
    unit =
      if value >= 100_000_000_000 do
        :millisecond
      else
        :second
      end

    DateTime.from_unix(value, unit)
  end

  def cast(value) when is_float(value), do: cast(trunc(value))

  def cast(_), do: :error

  @doc """
  Loads a timestamp value from the database. Because we might have a number of different formats we use (thanks to the weird typing of mongo), we just `cast/1` the value from the database to a DateTime struct.
  """
  @impl Ecto.Type
  def load(value), do: cast(value)

  @doc """
  We desire all timestamps going forward to be stored as `timestamp without time zone` in the underlying database schema. To accomplish this, we send all possible values of this type as ISO8601 formatted strings.
  """
  @impl Ecto.Type
  def dump(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  def dump(value) do
    case cast(value) do
      {:ok, datetime} -> dump(datetime)
      :error -> :error
    end
  end
end
