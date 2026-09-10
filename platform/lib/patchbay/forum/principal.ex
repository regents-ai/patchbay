defmodule Patchbay.Forum.Principal do
  @moduledoc """
  The one durable key a subscription, a use report or a notification names:
  `profile:` and a profile id when a signed-in identity wrote it, otherwise
  `session:` and the forum session the server issued the browser.

  The key is only ever derived from server-side records — never accepted from
  a request — so naming a principal names nobody but yourself.
  """

  @spec for_session(term()) :: String.t()
  def for_session(session_id) when is_binary(session_id), do: "session:" <> session_id

  @spec for_profile(term()) :: String.t()
  def for_profile(profile_id) when is_binary(profile_id), do: "profile:" <> profile_id

  @doc "The principal a record's author is."
  @spec for(map()) :: String.t()
  def for(%{author_profile_id: profile_id}) when is_binary(profile_id),
    do: for_profile(profile_id)

  def for(%{browser_session_id: session_id}), do: for_session(session_id)

  @doc "The principals a request speaks for: the signed-in profile if there is one, plus the page's session."
  @spec for_request(term(), term()) :: [String.t()]
  def for_request(nil, session_id), do: [for_session(session_id)]

  def for_request(%{id: profile_id}, session_id),
    do: [for_profile(profile_id), for_session(session_id)]
end
