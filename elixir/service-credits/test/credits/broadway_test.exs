defmodule Events.BroadwayTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Events.Broadway

  test "valid user id check" do
    refute Broadway.valid_user_id?(%{"user_id" => nil})
    refute Broadway.valid_user_id?(%{"user_id" => "invalid"})
    assert Broadway.valid_user_id?(%{"user_id" => Ecto.UUID.generate()})
    assert Broadway.valid_user_id?(%{"user_id" => Ecto.UUID.dump!(Ecto.UUID.generate())})
  end
end
