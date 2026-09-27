defmodule PatchbayWeb.ContentSecurityPolicy do
  @moduledoc """
  The content security policies the site's pages are served under.

  `reading/0` is the strict baseline: scripts, styles, images and fonts come
  from this site, requests and the live connection go back to it, no page frames
  another site or is framed itself, and forms submit only here.

  `sign_in/0` is the baseline plus exactly what Privy's wallet sign-in loads,
  taken from Privy's published policy and checked against the bundled Privy
  and WalletConnect code: Privy's API, frame and wallet RPC, Cloudflare
  Turnstile (when bot protection is on for the Privy app), WalletConnect's
  relays, verify frame, wallet list, logos, RPC and event reporting, Coinbase
  Wallet's relay, and the `blob:` images Privy's window draws. Privy's sign-in
  window writes its own style elements, so only this profile allows them.

  A Privy app that offers Telegram sign-in also needs `https://auth.privy.io`
  and `https://telegram.org` in `script-src` and `https://oauth.telegram.org` in
  `frame-src` (Privy's Telegram script is served from `auth.privy.io`; found on
  Regents' live sign-in pages, 2026-09-27).

  A site that loads anything else adds each origin to the one directive and the
  one profile that needs it. The wildcards are Privy's own `*.rpc.privy.systems`,
  from its published policy, and Google's `*.gstatic.com`, where its favicon
  service sends the icons it serves.
  """

  # The development code reloader runs in a frame from this site.
  @own_frames if Application.compile_env(:patchbay, [PatchbayWeb.Endpoint, :code_reloader]),
                do: ["'self'"],
                else: []

  @baseline [
    {"default-src", ["'none'"]},
    {"script-src", ["'self'"]},
    {"style-src", ["'self'"]},
    # Style attributes only, never style elements: the shared ratio card sizes
    # its fill with one. Rising words clip by class (`.split-clip`), not with one.
    {"style-src-attr", ["'unsafe-inline'"]},
    {"img-src", ["'self'", "data:"]},
    {"font-src", ["'self'"]},
    {"connect-src", ["'self'"]},
    {"frame-src", @own_frames},
    {"base-uri", ["'none'"]},
    {"form-action", ["'self'"]},
    {"frame-ancestors", ["'none'"]}
  ]

  @sign_in %{
    "script-src" => ["https://challenges.cloudflare.com"],
    "style-src" => ["'unsafe-inline'"],
    # Patchbay's pages, every one of which can sign in, also show the sites'
    # own icons (Google's favicon service, which answers from gstatic), the
    # sites' logos (Brandfetch), and Regents' logo in the sign-in window.
    "img-src" => [
      "blob:",
      "https://explorer-api.walletconnect.com",
      "https://www.google.com",
      "https://*.gstatic.com",
      "https://cdn.brandfetch.io",
      "https://regents.sh"
    ],
    "frame-src" => [
      "https://auth.privy.io",
      "https://verify.walletconnect.com",
      "https://verify.walletconnect.org",
      "https://challenges.cloudflare.com"
    ],
    "connect-src" => [
      "https://auth.privy.io",
      "https://*.rpc.privy.systems",
      "wss://relay.walletconnect.com",
      "wss://relay.walletconnect.org",
      "https://verify.walletconnect.org",
      "https://explorer-api.walletconnect.com",
      "https://rpc.walletconnect.org",
      "https://pulse.walletconnect.org",
      "wss://www.walletlink.org"
    ]
  }

  @doc "The strict baseline, for pages that never start sign-in."
  def reading, do: render(@baseline)

  @doc "The baseline plus Privy wallet sign-in, for pages that can sign someone in."
  def sign_in, do: @baseline |> add(@sign_in) |> render()

  defp add(directives, additions) do
    Enum.map(directives, fn {directive, sources} ->
      {directive, Enum.uniq(sources ++ Map.get(additions, directive, []))}
    end)
  end

  defp render(directives) do
    directives
    |> Enum.reject(fn {_directive, sources} -> sources == [] end)
    |> Enum.map_join("; ", fn {directive, sources} -> Enum.join([directive | sources], " ") end)
  end
end
