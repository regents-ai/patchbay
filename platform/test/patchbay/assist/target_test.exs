defmodule Patchbay.Assist.TargetTest do
  @moduledoc """
  An assist reaches a site only at a public address, connected to at the
  address that was checked, and reads a bounded answer.
  """

  use ExUnit.Case, async: true

  alias Patchbay.Assist.Target

  test "addresses off the public internet are refused, public ones pass" do
    refused = [
      {127, 0, 0, 1},
      {10, 1, 2, 3},
      {172, 16, 0, 1},
      {172, 31, 255, 255},
      {192, 168, 1, 1},
      {169, 254, 169, 254},
      {100, 64, 0, 1},
      {0, 0, 0, 0},
      {192, 0, 0, 1},
      {198, 18, 0, 1},
      {224, 0, 0, 1},
      {255, 255, 255, 255},
      {192, 88, 99, 1},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0xFC00, 0, 0, 0, 0, 0, 0, 1},
      {0xFD12, 0, 0, 0, 0, 0, 0, 1},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFEC0, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1},
      # ::ffff:127.0.0.1 and ::ffff:10.0.0.1, IPv4 carried inside IPv6
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001},
      {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
      # ::127.0.0.1, the old IPv4-compatible form
      {0, 0, 0, 0, 0, 0, 0x7F00, 0x0001},
      {0, 0, 0, 0, 0, 0, 0, 2},
      # 64:ff9b::169.254.169.254 and 64:ff9b:1::10.0.0.5 are translators'
      # addresses that reach an IPv4 host, never the site's own
      {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
      {0x64, 0xFF9B, 1, 0, 0, 0, 0x0A00, 0x0005},
      # 2002:7f00:1:: carries 127.0.0.1 the 6to4 way
      {0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0},
      "not an address"
    ]

    for address <- refused, do: refute(Target.public_address?(address), inspect(address))

    passed = [
      {8, 8, 8, 8},
      {172, 32, 0, 1},
      {100, 128, 0, 1},
      {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111},
      {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}
    ]

    for address <- passed, do: assert(Target.public_address?(address), inspect(address))
  end

  test "the connection goes to the checked address under the site's name, and follows nothing" do
    resolve = fn "example.com" -> [{93, 184, 216, 34}] end

    assert {:ok, target} =
             Target.connect("https://example.com/mcp?x=1", resolve: resolve)

    assert target.url == "https://93.184.216.34/mcp?x=1"
    assert target.host == "example.com"
    assert target.options[:finch] == [name: Target.finch(), pool_tag: "example.com"]
    assert {"host", "example.com"} in target.options[:headers]
    assert target.options[:redirect] == false
    assert target.options[:retry] == false

    # The pool for that address is verified as the site's name, and is the
    # one pool the site gets however often it is connected to.
    pool = Finch.Pool.new("https://93.184.216.34", tag: "example.com")
    assert {:ok, pid} = Finch.find_pool(Target.finch(), pool)
    assert {:ok, _again} = Target.connect("https://example.com/other", resolve: resolve)
    assert {:ok, ^pid} = Finch.find_pool(Target.finch(), pool)

    assert {:ok, six} =
             Target.connect("https://Example.com./",
               resolve: fn "example.com" -> [{0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111}] end
             )

    assert six.url == "https://[2606:4700::1111]/"

    assert {:ok, _pid} =
             Finch.find_pool(Target.finch(), Finch.Pool.new(six.url, tag: "example.com"))
  end

  test "only a plain https name on the default port is connected to" do
    resolve = fn _ -> [{93, 184, 216, 34}] end

    for url <- [
          "http://example.com/",
          "https://example.com:8443/",
          "https://user:pw@example.com/",
          "https:///mcp",
          "not a url"
        ] do
      assert {:error, :not_public} = Target.connect(url, resolve: resolve), url
    end
  end

  test "a name that resolves to any private address, or to nothing, is not connected to" do
    mixed = fn _ -> [{93, 184, 216, 34}, {10, 0, 0, 1}] end
    assert {:error, :not_public} = Target.connect("https://example.com/", resolve: mixed)

    assert {:error, :unresolvable} =
             Target.connect("https://example.com/", resolve: fn _ -> [] end)
  end
end
