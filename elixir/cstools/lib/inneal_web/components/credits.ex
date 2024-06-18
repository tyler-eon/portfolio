defmodule InnealWeb.Components.Credits do
  def date_format(date), do: date_format(date, "Etc/UTC")

  def date_format(nil, _), do: "never"
  def date_format(%DateTime{} = dt, timezone) do
    %{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
      zone_abbr: zone_abbr
    } = DateTime.shift_zone!(dt, timezone)
    "#{year}-#{pad_number(month)}-#{pad_number(day)} #{pad_number(hour)}:#{pad_number(minute)}:#{pad_number(second)} #{zone_abbr}"
  end
  def date_format(str, timezone) when is_binary(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    date_format(dt, timezone)
  end
  def date_format(num, timezone) when is_number(num) do
    trunc(num)
    |> DateTime.from_unix!(:millisecond)
    |> date_format(timezone)
  end

  defp pad_number(num) when num < 10, do: "0#{num}"
  defp pad_number(num), do: Integer.to_string(num)
end
