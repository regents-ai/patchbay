defmodule Patchbay.Offers.Source do
  @moduledoc """
  What a placement is for, as its `source_origin` names it: a listed site by
  its address, or one of Patchbay's own two, General and CVE incidents, by a
  name no site's address can take, since an address always has a dot. Each is
  created on the chain like any placement: its `source_id` is the hash of the
  name and its `metadata_uri` ends in it (`Patchbay.Offers.Events`).

  Which placements' offers go with a page is decided here, once, for every
  door (`order/1`): a page about a site shows the site's, the CVE incidents
  and each incident's page show CVE incidents', and General's are shown in
  their place while those have none for the reader. A page about no one site
  shows General's.
  """

  @general "general"
  @incidents "incidents"

  @typedoc "What a page or answer is about, for its offers."
  @type about :: {:site, String.t()} | :incidents | :general

  @doc "General's name: the placement shown wherever a page's own has no offer."
  @spec general() :: String.t()
  def general, do: @general

  @doc "CVE incidents' name: the placement shown with the incidents."
  @spec incidents() :: String.t()
  def incidents, do: @incidents

  @doc """
  The sources whose offers may go with a page about `about`, in the order they
  are tried: the first with an offer for the reader is the one shown.
  """
  @spec order(about()) :: [String.t(), ...]
  def order({:site, origin}), do: [origin, @general]
  def order(:incidents), do: [@incidents, @general]
  def order(:general), do: [@general]

  @doc "Whether a placement's source is General or CVE incidents, Patchbay's own two."
  @spec own?(String.t() | nil) :: boolean()
  def own?(origin), do: origin in [@general, @incidents]

  @doc "Whether a placement's source is a listed site."
  @spec site?(String.t() | nil) :: boolean()
  def site?(origin), do: is_binary(origin) and not own?(origin)

  @doc """
  Where a placement's source comes in a list of placements: General, CVE
  incidents, then each site by its address, a site Patchbay does not list
  last.
  """
  @spec rank(String.t() | nil) :: {0..3, String.t()}
  def rank(@general), do: {0, ""}
  def rank(@incidents), do: {1, ""}
  def rank(nil), do: {3, ""}
  def rank(origin), do: {2, origin}

  @doc "How a page names a placement's source."
  @spec label(String.t() | nil) :: String.t()
  def label(@general), do: "General"
  def label(@incidents), do: "CVE incidents"
  def label(nil), do: "Unlisted site"
  def label(origin), do: origin
end
