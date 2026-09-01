alias Elixir.Patchbay.Patchbay, as: Domain
alias Elixir.Patchbay.Patchbay.Fixtures, as: Fixtures

room =
  case Domain.list_rooms!(query: [filter: [slug: Fixtures.slug()], limit: 1]) do
    [room | _] -> room
    [] -> Domain.create_seeded_room!()
  end

case Domain.list_tool_revisions!(query: [filter: [room_id: room.id, generation: 1], limit: 1]) do
  [] ->
    Fixtures.revision_attributes(room.id)
    |> Map.delete(:contract_sha256)
    |> Domain.create_tool_revision!()

  _ ->
    :ok
end
