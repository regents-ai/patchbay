# SSRF regression probe for Patchbay.Assist.Target (the one guard every
# site-fetch feature routes through: site checks, the site refresh button,
# the For-agents panel scan, MCP tool reads, offer-destination checks).
#
# Run:  direnv exec . mix run --no-start scripts/security/ssrf_target_probe.exs
#
# It asserts that a name resolving to a non-public address (loopback, private,
# link-local, cloud metadata, IPv4-mapped IPv6, NAT64, 6to4) is refused with
# {:error, :not_public} BEFORE any socket is opened, and that a plain public
# address is admitted. `resolve:` stands in for DNS so the probe needs no
# network and is deterministic; it exercises the real connect/2 gate and the
# real public_address?/1 classifier.

alias Patchbay.Assist.Target

defmodule Probe do
  def check(label, expected, got) do
    ok? =
      case {expected, got} do
        {:refused, {:error, reason}} when reason in [:not_public, :unresolvable] -> true
        {:admitted, {:ok, _}} -> true
        _ -> false
      end

    IO.puts([
      if(ok?, do: "PASS  ", else: "FAIL  "),
      String.pad_trailing(label, 42),
      inspect(got)
    ])

    unless ok?, do: Process.put(:failed, true)
  end
end

# host -> addresses the (stand-in) resolver returns
blocked = [
  {"loopback v4 127.0.0.1", [{127, 0, 0, 1}]},
  {"loopback v4 127.9.9.9", [{127, 9, 9, 9}]},
  {"0.0.0.0", [{0, 0, 0, 0}]},
  {"private 10.x", [{10, 0, 0, 5}]},
  {"private 172.16.x", [{172, 16, 3, 4}]},
  {"private 192.168.x", [{192, 168, 1, 1}]},
  {"CGNAT 100.64.x", [{100, 64, 0, 1}]},
  {"link-local 169.254.x", [{169, 254, 1, 1}]},
  {"AWS metadata 169.254.169.254", [{169, 254, 169, 254}]},
  {"multicast 224.x", [{224, 0, 0, 1}]},
  {"IPv6 loopback ::1", [{0, 0, 0, 0, 0, 0, 0, 1}]},
  {"IPv6 ULA fd00::", [{0xFD00, 0, 0, 0, 0, 0, 0, 1}]},
  {"IPv6 link-local fe80::", [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]},
  {"GCP metadata fd00:ec2::254", [{0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}]},
  {"IPv4-mapped ::ffff:127.0.0.1", [{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}]},
  {"NAT64 64:ff9b::7f00:1", [{0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001}]},
  {"6to4 2002::", [{0x2002, 0, 0, 0, 0, 0, 0, 1}]},
  # one public + one private: all addresses must pass, so this is refused
  {"mixed public+private", [{1, 1, 1, 1}, {127, 0, 0, 1}]}
]

allowed = [
  {"public v4 1.1.1.1", [{1, 1, 1, 1}]},
  {"public v6 2606:4700::", [{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}]}
]

# A public address is pinned into a Finch pool, so start Finch for that case.
{:ok, _} = Finch.start_link(name: Target.finch())

IO.puts("== connect/2 gate (https host, DNS stand-in) ==")

for {label, addrs} <- blocked do
  got = Target.connect("https://redteam.example", resolve: fn _host -> addrs end)
  Probe.check(label, :refused, got)
end

for {label, addrs} <- allowed do
  got = Target.connect("https://redteam.example", resolve: fn _host -> addrs end)
  Probe.check(label, :admitted, got)
end

IO.puts("\n== scheme / port / userinfo gate ==")
# non-https, non-443, and userinfo are refused regardless of address
Probe.check("http:// refused", :refused, Target.connect("http://redteam.example", resolve: fn _ -> [{1, 1, 1, 1}] end))
Probe.check("https :8080 refused", :refused, Target.connect("https://redteam.example:8080", resolve: fn _ -> [{1, 1, 1, 1}] end))
Probe.check("userinfo refused", :refused, Target.connect("https://u:p@redteam.example", resolve: fn _ -> [{1, 1, 1, 1}] end))

if Process.get(:failed), do: System.halt(1), else: IO.puts("\nALL PASS")
