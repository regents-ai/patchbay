defmodule Patchbay.Patchbay.Digest do
  @moduledoc """
  Digest and generation-key helpers used by Patchbay's durable evidence.
  """

  alias Patchbay.Patchbay.CanonicalJSON

  @max_artifact_bytes 65_536

  @spec sha256(binary()) :: String.t()
  def sha256(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  @spec artifact_size(binary()) :: non_neg_integer()
  def artifact_size(value) when is_binary(value), do: byte_size(value)

  @spec validate_artifact(binary()) :: :ok | {:error, :artifact_too_large}
  def validate_artifact(value) when is_binary(value) do
    if byte_size(value) <= @max_artifact_bytes, do: :ok, else: {:error, :artifact_too_large}
  end

  @spec max_artifact_bytes() :: pos_integer()
  def max_artifact_bytes, do: @max_artifact_bytes

  @doc """
  The JSON form of a tool contract, from a revision record or the same fields
  as a plain map.
  """
  @spec contract_payload(map()) :: map()
  def contract_payload(revision) do
    %{
      "name" => Map.get(revision, :name),
      "title" => Map.get(revision, :title),
      "description" => Map.get(revision, :description),
      "input_schema" => Map.get(revision, :input_schema) || %{},
      "annotations" => Map.get(revision, :annotations) || %{},
      "handler_adapter" => Map.get(revision, :handler_adapter),
      "output_contract" => Map.get(revision, :output_contract) || %{},
      "postcondition_set" => Map.get(revision, :postcondition_set)
    }
  end

  @spec contract_sha256(map()) :: String.t()
  def contract_sha256(revision),
    do: revision |> contract_payload() |> CanonicalJSON.encode() |> sha256()

  @spec arguments_sha256(map()) :: String.t()
  def arguments_sha256(arguments) when is_map(arguments),
    do: arguments |> CanonicalJSON.encode() |> sha256()

  @spec generation_key(binary(), map()) :: String.t()
  def generation_key(source_sha256, arguments)
      when is_binary(source_sha256) and is_map(arguments) do
    sha256(source_sha256 <> <<0>> <> CanonicalJSON.encode(arguments))
  end
end
