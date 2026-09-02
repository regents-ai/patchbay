defmodule Patchbay.Patchbay.ResourcesTest do
  use Patchbay.DataCase, async: false

  require Ash.Query

  alias Elixir.Patchbay.Patchbay

  alias Elixir.Patchbay.Patchbay.{
    BrowserSession,
    DemoReset,
    Digest,
    Fixtures,
    Invocation,
    RoomEvent,
    RoomTimeline,
    ToolPublisher,
    ToolRevision,
    Verification,
    VerificationService
  }

  setup do
    room = Patchbay.create_seeded_room!("room-#{System.unique_integer([:positive])}")

    revision = seeded_revision!(room)

    %{room: room, revision: revision}
  end

  test "source and candidate writes recompute digests and advance the UI revision", %{
    room: room
  } do
    source = room.source_markdown <> "\n"
    room = Patchbay.update_source!(room, source)

    assert room.source_sha256 == Digest.sha256(source)

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    assert room.candidate_sha256 == Digest.sha256(Fixtures.improved_markdown())
    assert room.ui_revision == 1
  end

  test "source and candidate markdown are bounded by UTF-8 byte size", %{room: room} do
    oversized = String.duplicate("🙂", div(Digest.max_artifact_bytes(), 4) + 1)

    assert byte_size(oversized) > Digest.max_artifact_bytes()
    assert_raise Ash.Error.Invalid, fn -> Patchbay.update_source!(room, oversized) end
    assert_raise Ash.Error.Invalid, fn -> Patchbay.apply_candidate!(room, oversized) end
  end

  test "blank candidates fail without advancing the UI revision", %{room: room} do
    assert_raise Ash.Error.Invalid, fn -> Patchbay.apply_candidate!(room, nil) end
    assert_raise Ash.Error.Invalid, fn -> Patchbay.apply_candidate!(room, " \n\t") end

    fresh_room = Patchbay.get_room_by_slug!(room.slug)
    assert fresh_room.ui_revision == 0
    assert fresh_room.candidate_markdown == nil
  end

  test "room slug and browser client instance identities are unique", %{room: room} do
    assert_raise Ash.Error.Invalid, fn -> Patchbay.create_seeded_room!(room.slug) end

    client_instance_id = Ash.UUID.generate()

    attrs = %{
      room_id: room.id,
      client_instance_id: client_instance_id,
      user_agent_digest: Digest.sha256("test-agent")
    }

    Patchbay.register_browser_session!(attrs)
    reconnected = Patchbay.register_browser_session!(attrs)
    assert reconnected.id == Patchbay.get_browser_session!(reconnected.id).id
  end

  test "browser registration cannot supply observations or revive a reset session", %{
    room: room,
    revision: revision
  } do
    client_instance_id = Ash.UUID.generate()

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: client_instance_id,
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true,
        desired_generation: revision.generation,
        observed_generation: revision.generation,
        observed_contracts: %{revision.name => revision.contract_sha256}
      })
    end

    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: client_instance_id,
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    Patchbay.observe_browser_session!(browser_session, :toolchange, %{
      observed_generation: revision.generation,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    DemoReset.reset!(room)

    reconnected =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: client_instance_id,
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    assert reconnected.id == browser_session.id
    reset_session = Patchbay.get_browser_session!(browser_session.id)
    assert reset_session.disconnected_at
    assert reset_session.observed_generation == nil
    assert reset_session.observed_contracts == %{}

    Patchbay.observe_browser_session!(reset_session, :toolchange, %{
      desired_generation: revision.generation + 1,
      observed_generation: revision.generation + 1,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    assert Patchbay.get_browser_session!(browser_session.id).disconnected_at

    Patchbay.observe_browser_session!(reset_session, :toolchange, %{
      desired_generation: revision.generation,
      observed_generation: revision.generation,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    refute Patchbay.get_browser_session!(browser_session.id).disconnected_at
  end

  test "an observed registry has to be the room's own toolset", %{
    room: room,
    revision: revision
  } do
    session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent"),
        webmcp_supported: true
      })

    names = [revision.name | BrowserSession.permanent_tool_names()]

    contracts =
      Map.new(names, fn name ->
        {name, if(name == revision.name, do: revision.contract_sha256, else: Digest.sha256(name))}
      end)

    whole = %{
      observed_generation: 1,
      observed_tool_names: names,
      observed_contracts: contracts
    }

    assert Patchbay.observe_browser_session!(session, :reconciled, whole).observed_tool_names ==
             names

    # A reconciliation reports the whole registry, so a partial one is refused.
    # A toolchange reports the one registration that has just happened.
    one_tool = %{
      observed_generation: 1,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    }

    assert_raise Ash.Error.Invalid, ~r/complete desired Patchbay toolset/, fn ->
      Patchbay.observe_browser_session!(session, :reconciled, one_tool)
    end

    assert Patchbay.observe_browser_session!(session, :toolchange, one_tool).observed_tool_names ==
             [revision.name]

    assert_raise Ash.Error.Invalid, ~r/reconciliation or a toolchange/, fn ->
      Patchbay.observe_browser_session!(session, :guessed, whole)
    end

    assert_raise Ash.Error.Invalid, ~r/must match the room's desired generation/, fn ->
      Patchbay.observe_browser_session!(session, :toolchange, %{observed_generation: 2})
    end

    assert_raise Ash.Error.Invalid, ~r/must not contain duplicates/, fn ->
      Patchbay.observe_browser_session!(session, :toolchange, %{
        observed_generation: 1,
        observed_tool_names: [revision.name, revision.name],
        observed_contracts: %{revision.name => revision.contract_sha256}
      })
    end

    assert_raise Ash.Error.Invalid, ~r/SHA-256 digests/, fn ->
      Patchbay.observe_browser_session!(session, :toolchange, %{
        observed_generation: 1,
        observed_tool_names: [revision.name],
        observed_contracts: %{revision.name => "not-a-digest"}
      })
    end

    assert_raise Ash.Error.Invalid, ~r/exactly cover the observed tool names/, fn ->
      Patchbay.observe_browser_session!(session, :toolchange, %{
        observed_generation: 1,
        observed_tool_names: [],
        observed_contracts: %{revision.name => revision.contract_sha256}
      })
    end

    assert_raise Ash.Error.Invalid, ~r/Patchbay does not own/, fn ->
      Patchbay.observe_browser_session!(session, :toolchange, %{
        observed_generation: 1,
        observed_tool_names: ["foreign_tool"],
        observed_contracts: %{"foreign_tool" => String.duplicate("f", 64)}
      })
    end

    assert_raise Ash.Error.Invalid, ~r/does not match the desired revision/, fn ->
      Patchbay.observe_browser_session!(session, :toolchange, %{
        observed_generation: 1,
        observed_tool_names: [revision.name],
        observed_contracts: %{revision.name => String.duplicate("a", 64)}
      })
    end

    kept = Patchbay.get_browser_session!(session.id)
    assert kept.observed_tool_names == [revision.name]
    assert kept.observed_contracts == %{revision.name => revision.contract_sha256}
  end

  test "invocation pre-state capture is a transaction-bound before-action hook", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    changeset =
      Ash.Changeset.for_create(
        Invocation,
        :record_invocation,
        %{
          request_uuid: Ash.UUID.generate(),
          room_id: room.id,
          browser_session_id: browser_session.id,
          tool_revision_id: revision.id,
          tool_contract_sha256: revision.contract_sha256,
          arguments: %{}
        }
      )

    action = Ash.Resource.Info.action(Invocation, :record_invocation)

    assert changeset.before_action != []
    assert changeset.action.transaction?
    assert Elixir.Patchbay.Patchbay.Room in action.touches_resources
  end

  test "invocation pre-state is captured from the locked room", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    assert invocation.pre_state == %{
             ui_revision: 0,
             source: %{present: true, sha256: room.source_sha256},
             candidate: %{present: false, sha256: nil}
           }

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        pre_state: invocation.pre_state
      })
    end
  end

  test "evidence relationships must belong to their room", %{room: room, revision: revision} do
    other_room = Patchbay.create_seeded_room!("other-room")
    other_revision = seeded_revision!(other_room)

    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: other_room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })
    end

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: other_room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: other_revision.id,
        tool_contract_sha256: other_revision.contract_sha256,
        arguments: %{}
      })

    assert_raise Ash.Error.Invalid, fn -> Patchbay.record_failure!(room, invocation.id) end

    assert_raise Ash.Error.Invalid, fn ->
      create_verification!(%{
        room_id: room.id,
        invocation_id: invocation.id,
        observed_state: %{}
      })
    end

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.append_room_event!(%{
        room_id: room.id,
        browser_session_id: browser_session.id,
        sequence: 99,
        kind: :visible_state_observed,
        payload: %{}
      })
    end

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.create_repair_proposal!(%{
        room_id: room.id,
        source_invocation_id: invocation.id,
        source_tool_revision_id: other_revision.id,
        root_cause: "test",
        repair_plan: %{},
        contract_diff: %{},
        canary_result: %{},
        risk_notes: [],
        model: "fixture",
        model_response_id: "fixture-response",
        prompt_version: "v1",
        input_sha256: Digest.sha256("proposal")
      })
    end
  end

  test "generated candidate digest is recomputed and size bounded", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    candidate = Fixtures.improved_markdown()

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        generated_candidate: candidate
      })

    assert invocation.generated_candidate_sha256 == Digest.sha256(candidate)

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        generated_candidate: candidate,
        generated_candidate_sha256: Digest.sha256("wrong")
      })
    end

    oversized = String.duplicate("🙂", div(Digest.max_artifact_bytes(), 4) + 1)

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        generated_candidate: oversized
      })
    end
  end

  test "verified success is derived by the verifier, never claimed", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        effective_status: :verified_success
      })
    end

    # Recording a verification for a call that never changed the room writes
    # the verifier's own verdict, with every check it makes accounted for.
    verification =
      create_verification!(%{
        room_id: room.id,
        invocation_id: invocation.id,
        observed_state: %{"candidate" => %{"present" => true}}
      })

    required_checks = Elixir.Patchbay.Patchbay.PostconditionVerifier.required_checks()

    refute verification.passed
    assert verification.failure_code
    assert Enum.sort(Map.keys(verification.checks)) == Enum.sort(required_checks)
    refute Enum.all?(required_checks, &verification.checks[&1])
  end

  test "invocation verification status follows the verifier result", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    failed =
      VerificationService.verify_invocation!(invocation, %{
        post_state:
          visible_post_state(room)
          |> put_in(["candidate", "present"], true)
      })

    assert failed.effective_status == :verified_failure

    successful_invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        generated_candidate: Fixtures.improved_markdown()
      })

    Patchbay.observe_browser_session!(browser_session, :toolchange, %{
      observed_generation: revision.generation,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    verified =
      VerificationService.verify_invocation!(successful_invocation, %{
        post_state: visible_post_state(room)
      })

    assert verified.effective_status == :verified_success

    retried =
      VerificationService.verify_invocation!(successful_invocation, %{
        post_state:
          visible_post_state(room)
          |> Map.put("tool_contract_sha256", "caller-forged")
          |> Map.put("browser_session_id", Ash.UUID.generate())
      })

    assert retried.effective_status == :verified_success

    assert [verification] =
             Ash.read!(
               Elixir.Patchbay.Patchbay.Verification
               |> Ash.Query.filter(invocation_id: successful_invocation.id)
             )

    assert verification.passed

    failed_retry = VerificationService.verify_invocation!(invocation, %{post_state: %{}})
    assert failed_retry.effective_status == :verified_failure
  end

  test "verification persistence is service-only and reloads forged invocation structs", %{
    room: room,
    revision: revision
  } do
    refute function_exported?(Patchbay, :record_invocation_verification!, 2)
    refute function_exported?(Patchbay, :record_verification!, 1)

    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        generated_candidate: Fixtures.improved_markdown()
      })

    Patchbay.observe_browser_session!(browser_session, :toolchange, %{
      observed_generation: revision.generation,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    forged = %{
      invocation
      | effective_status: :verified_success,
        failure_code: nil,
        pre_state: %{},
        generated_candidate: "forged",
        generated_candidate_sha256: Digest.sha256("forged")
    }

    verified =
      VerificationService.verify_invocation!(forged, %{
        post_state: visible_post_state(room)
      })

    assert verified.id == invocation.id
    assert verified.effective_status == :verified_success
    assert verified.generated_candidate == invocation.generated_candidate
  end

  test "an existing verification reconciles the invocation before returning", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        generated_candidate: Fixtures.improved_markdown()
      })

    Patchbay.observe_browser_session!(browser_session, :toolchange, %{
      observed_generation: revision.generation,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    post_state = visible_post_state(room)

    verification =
      create_verification!(%{
        room_id: room.id,
        invocation_id: invocation.id,
        observed_state: post_state
      })

    stale_verified_at = DateTime.add(verification.inserted_at, -60, :second)

    # The durable verification exists while its invocation projection is stale.
    assert invocation.effective_status == :started

    reconciled = VerificationService.verify_invocation!(invocation, %{post_state: post_state})

    assert reconciled.effective_status == :verified_success
    assert reconciled.failure_code == nil
    assert reconciled.post_state == verification.observed_state
    assert reconciled.verified_at == verification.inserted_at
    refute reconciled.verified_at == stale_verified_at
  end

  test "verification freshness comes from the persisted browser session", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{},
        pre_state: %{
          ui_revision: room.ui_revision,
          source: %{present: true, sha256: room.source_sha256},
          candidate: %{present: false, sha256: nil}
        },
        generated_candidate: Fixtures.improved_markdown()
      })

    Patchbay.observe_browser_session!(browser_session, :toolchange, %{
      observed_generation: revision.generation,
      observed_tool_names: [revision.name],
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())
    Patchbay.disconnect_browser_session!(browser_session, %{disconnected_at: DateTime.utc_now()})

    verified =
      VerificationService.verify_invocation!(invocation, %{
        post_state:
          visible_post_state(room)
          |> Map.put("tool_contract_sha256", revision.contract_sha256)
          |> Map.put("browser_session_id", browser_session.id)
      })

    assert verified.effective_status == :verified_failure
    assert verified.failure_code == :STALE_BROWSER_SESSION
  end

  test "proposal publication requires approval, a passed canary, and current evidence", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    proposal =
      Patchbay.create_repair_proposal!(%{
        room_id: room.id,
        source_invocation_id: invocation.id,
        source_tool_revision_id: revision.id,
        root_cause: "test",
        repair_plan: %{},
        contract_diff: %{},
        canary_result: %{passed: false},
        risk_notes: [],
        model: "fixture",
        model_response_id: "fixture-response",
        prompt_version: "v1",
        input_sha256: Digest.sha256("proposal")
      })

    assert_raise Ash.Error.Invalid, fn -> Patchbay.publish_repair_proposal!(proposal) end

    canary_checks = Map.new(Elixir.Patchbay.Patchbay.RepairProposal.canary_checks(), &{&1, true})

    proposal =
      Patchbay.mark_canary_passed!(proposal, %{
        canary_result: %{passed: true, checks: canary_checks}
      })

    # Approval also requires the repair to still answer the room's current
    # verified failure, which this hand-built proposal never did.
    assert_raise Ash.Error.Invalid, ~r/moved on from this failed call/, fn ->
      Patchbay.approve_repair_proposal!(proposal, "founder")
    end

    assert_raise Ash.Error.Invalid, ~r/must equal :approved/, fn ->
      Patchbay.publish_repair_proposal!(proposal)
    end
  end

  test "room repair transitions only accept their legal prior status", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    assert room.status == :ready

    assert_raise Ash.Error.Invalid, ~r/must equal :diagnosing/, fn ->
      Patchbay.mark_repair_ready!(room)
    end

    assert_raise Ash.Error.Invalid, ~r/must equal :awaiting_approval/, fn ->
      Patchbay.begin_publication!(room)
    end

    assert_raise Ash.Error.Invalid, ~r/must equal :publishing/, fn ->
      Patchbay.mark_repaired!(room)
    end

    assert_raise Ash.Error.Invalid, ~r/must equal :repaired/, fn ->
      Patchbay.begin_retry!(room)
    end

    assert_raise Ash.Error.Invalid, ~r/must equal :retrying/, fn ->
      Patchbay.mark_verified!(room)
    end

    assert_raise Ash.Error.Invalid, fn -> Patchbay.begin_diagnosis!(room) end

    room = Patchbay.record_failure!(room, invocation.id)
    assert room.status == :failed

    # The page starts the diagnosis when the owner asks, and the planner starts
    # it again once it holds the room, so the second one is legal.
    room = room |> Patchbay.begin_diagnosis!() |> Patchbay.begin_diagnosis!()

    # Parking the room on a decision is named by no policy, so the test reaches
    # it the way the planner does.
    room =
      room
      |> Patchbay.mark_repair_ready!()
      |> Patchbay.await_repair_approval!(authorize?: false)

    room = room |> Patchbay.begin_publication!() |> Patchbay.mark_repaired!()
    room = Patchbay.begin_retry!(room)

    assert Patchbay.mark_verified!(room).status == :verified
  end

  test "tool revision lifecycle actions only accept their legal prior status", %{
    room: room,
    revision: revision
  } do
    assert revision.status == :desired

    assert_raise Ash.Error.Invalid, ~r/must equal :candidate/, fn ->
      Patchbay.mark_tool_revision_canary_passed!(revision)
    end

    candidate =
      Fixtures.revision_attributes(room.id)
      |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2", status: :candidate})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()

    assert_raise Ash.Error.Invalid, ~r/must equal :ready_for_approval/, fn ->
      Patchbay.mark_tool_revision_approved!(candidate)
    end

    candidate =
      candidate
      |> Patchbay.mark_tool_revision_canary_passed!()
      |> Patchbay.mark_tool_revision_ready_for_approval!()
      |> Patchbay.mark_tool_revision_approved!()

    retired = Patchbay.retire_tool_revision!(candidate)
    assert retired.status == :retired

    assert_raise Ash.Error.Invalid, fn -> Patchbay.retire_tool_revision!(retired) end
  end

  test "unknown reset slugs return not found", %{room: _room} do
    assert_raise Ash.Error.Query.NotFound, fn -> DemoReset.reset!("does-not-exist") end
  end

  test "a room's internal moves and its deletion are named by no policy", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    # Each move checks its prior status before anything else, so the room is
    # walked to the status the move expects and is then refused for the policy.
    diagnosing = room |> Patchbay.record_failure!(invocation.id) |> Patchbay.begin_diagnosis!()

    assert {:error, %Ash.Error.Forbidden{}} = Patchbay.mark_repair_failed(diagnosing)
    assert {:error, %Ash.Error.Forbidden{}} = Patchbay.discard_room(diagnosing)

    assert {:error, %Ash.Error.Forbidden{}} =
             Patchbay.set_active_repair_proposal(diagnosing,
               private_arguments: %{proposal_id: nil}
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             diagnosing
             |> Ash.Changeset.for_update(:set_desired_tool_generation, %{},
               domain: Patchbay,
               private_arguments: %{generation: 2}
             )
             |> Ash.update()

    ready = Patchbay.mark_repair_ready!(diagnosing)
    assert {:error, %Ash.Error.Forbidden{}} = Patchbay.await_repair_approval(ready)

    # The planner and the page reach the two moves deliberately, and still can.
    waiting = Patchbay.await_repair_approval!(ready, authorize?: false)
    assert waiting.status == :awaiting_approval

    diagnosing_again =
      waiting |> Patchbay.record_failure!(invocation.id) |> Patchbay.begin_diagnosis!()

    assert Patchbay.mark_repair_failed!(diagnosing_again, authorize?: false).status == :error
  end

  test "tool revisions expose only lifecycle updates, leaving contracts immutable", %{
    revision: revision
  } do
    assert_raise RuntimeError, fn -> Ash.update!(revision, %{name: "changed"}) end
    assert_raise RuntimeError, fn -> Ash.update!(revision, %{status: :desired}) end

    retired = Patchbay.retire_tool_revision!(revision)
    assert retired.status == :retired
    assert retired.name == revision.name
    assert retired.contract_sha256 == revision.contract_sha256
  end

  test "at most one desired revision exists for a room", %{room: room, revision: revision} do
    assert_raise Ash.Error.Invalid, fn ->
      Fixtures.revision_attributes(room.id)
      |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2"})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()
    end

    assert Patchbay.retire_tool_revision!(revision).status == :retired

    revision =
      Fixtures.revision_attributes(room.id)
      |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2"})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()

    assert revision.status == :desired
    assert Patchbay.get_room_by_slug!(room.slug).desired_tool_generation == 2
  end

  test "a retired generation can be recreated for a later demo run", %{
    room: room,
    revision: revision
  } do
    assert Patchbay.retire_tool_revision!(revision).status == :retired

    recreated =
      Fixtures.revision_attributes(room.id)
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()

    assert recreated.generation == revision.generation
    assert recreated.id != revision.id
    assert recreated.status == :desired
  end

  test "tool publication updates the room desired generation with the revision", %{
    room: room,
    revision: revision
  } do
    _ = Patchbay.retire_tool_revision!(revision)

    candidate =
      Fixtures.revision_attributes(room.id)
      |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2", status: :candidate})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()

    assert_raise ArgumentError, fn -> ToolPublisher.sync_room_generation!(candidate) end
    assert Patchbay.get_room_by_slug!(room.slug).desired_tool_generation == 1

    published = ToolPublisher.publish!(candidate)
    assert published.status == :desired
    assert Patchbay.get_room_by_slug!(room.slug).desired_tool_generation == 2
  end

  test "publishing a revision retires the one the room was still offering", %{
    room: room,
    revision: revision
  } do
    published =
      Fixtures.revision_attributes(room.id)
      |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2", status: :candidate})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()
      |> ToolPublisher.publish!()

    assert published.status == :desired
    assert Patchbay.get_tool_revision!(revision.id).status == :retired
    assert Patchbay.get_room_by_slug!(room.slug).desired_tool_generation == 2
  end

  test "a proposal cannot be created in an approved state", %{room: room, revision: revision} do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{"instructions" => "clarify the skill"}
      })

    assert_raise Ash.Error.Invalid, fn ->
      Patchbay.create_repair_proposal!(%{
        room_id: room.id,
        source_invocation_id: invocation.id,
        source_tool_revision_id: revision.id,
        status: :approved,
        root_cause: "The handler did not update visible state.",
        repair_plan: %{},
        contract_diff: %{},
        canary_result: %{passed: true},
        risk_notes: [],
        model: "fixture",
        model_response_id: "fixture-response",
        prompt_version: "v1",
        input_sha256: Digest.sha256("proposal"),
        approved_by: "not-a-human-action",
        approved_at: DateTime.utc_now()
      })
    end
  end

  test "demo reset restores room, retires generated revisions, and records timeline event", %{
    room: room,
    revision: revision
  } do
    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    browser_session =
      Patchbay.observe_browser_session!(browser_session, :toolchange, %{
        observed_generation: revision.generation,
        observed_tool_names: [revision.name],
        observed_contracts: %{revision.name => revision.contract_sha256},
        webmcp_supported: true,
        toolchange_count: 2
      })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    failed_invocation =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{}
      })

    room = Patchbay.record_failure!(room, failed_invocation.id)
    assert room.status == :failed

    _ = Patchbay.retire_tool_revision!(revision)

    Fixtures.revision_attributes(room.id)
    |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2", status: :desired})
    |> Map.delete(:contract_sha256)
    |> Patchbay.create_tool_revision!()

    reset = DemoReset.reset!(room)

    assert reset.status == :ready
    assert reset.ui_revision == 0
    assert reset.invocation_epoch == room.invocation_epoch + 1
    assert reset.candidate_markdown == nil
    assert reset.candidate_sha256 == nil
    assert reset.desired_tool_generation == 1
    assert reset.source_markdown == Fixtures.source_markdown()
    assert reset.source_sha256 == Digest.sha256(Fixtures.source_markdown())
    assert reset.last_failed_invocation_id == nil
    assert reset.active_repair_proposal_id == nil

    reset_browser_session = Patchbay.get_browser_session!(browser_session.id)
    assert reset_browser_session.disconnected_at
    assert reset_browser_session.webmcp_supported == false
    assert reset_browser_session.desired_generation == 1
    assert reset_browser_session.observed_generation == nil
    assert reset_browser_session.observed_tool_names == []
    assert reset_browser_session.observed_contracts == %{}
    assert reset_browser_session.toolchange_count == 0

    revisions =
      Patchbay.list_tool_revisions!(
        query: [filter: [room_id: reset.id], sort: [generation: :asc]]
      )

    assert [
             %ToolRevision{generation: 1, status: :desired},
             %ToolRevision{generation: 2, status: :retired}
           ] = revisions

    [event | _] =
      Patchbay.list_room_events!(
        query: [filter: [room_id: reset.id], sort: [sequence: :desc], limit: 1]
      )

    assert %RoomEvent{kind: :room_reset, sequence: 1} = event
  end

  test "the timeline read hands back one page of a room's newest events", %{room: room} do
    page_size = RoomEvent.page_size()
    overflow = 3

    Ash.bulk_create!(
      for sequence <- 1..(page_size + overflow) do
        %{room_id: room.id, sequence: sequence, kind: :room_reset, payload: %{}}
      end,
      RoomEvent,
      :append
    )

    recent = Patchbay.list_recent_room_events!(room.id)

    assert length(recent) == page_size
    assert List.first(recent).sequence == page_size + overflow
    assert List.last(recent).sequence == overflow + 1

    assert Enum.map(RoomTimeline.list!(room.id), & &1.sequence) ==
             Enum.to_list((overflow + 1)..(page_size + overflow))
  end

  test "demo reset recreates and publishes a missing generation-one revision", %{
    room: room,
    revision: revision
  } do
    revision_id = Ecto.UUID.dump!(revision.id)

    assert %{num_rows: 1} =
             Repo.query!("DELETE FROM tool_revisions WHERE id = $1", [revision_id])

    reset = DemoReset.reset!(room)

    assert [recreated] =
             Patchbay.list_tool_revisions!(
               query: [filter: [room_id: reset.id, generation: 1], limit: 1]
             )

    assert recreated.status == :desired
  end

  test "a room names the tool it offers, the call it is showing and the repair it is holding", %{
    room: room,
    revision: revision
  } do
    loaded =
      Patchbay.get_room_by_id!(room.id,
        load: [
          :desired_tool_revision,
          latest_invocation: [:tool_revision],
          active_repair_proposal: [:source_tool_revision, :candidate_tool_revision]
        ]
      )

    assert loaded.desired_tool_revision.id == revision.id
    assert is_nil(loaded.latest_invocation)
    assert is_nil(loaded.active_repair_proposal)

    browser_session =
      Patchbay.register_browser_session!(%{
        room_id: room.id,
        client_instance_id: Ash.UUID.generate(),
        user_agent_digest: Digest.sha256("test-agent")
      })

    _older =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{"instructions" => "first"}
      })

    newest =
      Patchbay.record_invocation!(%{
        request_uuid: Ash.UUID.generate(),
        room_id: room.id,
        browser_session_id: browser_session.id,
        tool_revision_id: revision.id,
        tool_contract_sha256: revision.contract_sha256,
        arguments: %{"instructions" => "second"}
      })

    proposal =
      Patchbay.create_repair_proposal!(%{
        room_id: room.id,
        source_invocation_id: newest.id,
        source_tool_revision_id: revision.id,
        root_cause: "The handler did not update visible state.",
        repair_plan: %{},
        contract_diff: %{},
        canary_result: %{passed: true},
        risk_notes: [],
        model: "fixture",
        model_response_id: "fixture-response",
        prompt_version: "v1",
        input_sha256: Digest.sha256("proposal")
      })

    # The pointer is named by no policy, so the test sets it the way the planner
    # does.
    Patchbay.set_active_repair_proposal!(room,
      authorize?: false,
      private_arguments: %{proposal_id: proposal.id}
    )

    loaded =
      Patchbay.get_room_by_id!(room.id,
        load: [
          :desired_tool_revision,
          latest_invocation: [:tool_revision],
          active_repair_proposal: [:source_tool_revision, :candidate_tool_revision]
        ]
      )

    assert loaded.latest_invocation.id == newest.id
    assert loaded.latest_invocation.tool_revision.id == revision.id
    assert loaded.active_repair_proposal.id == proposal.id
    assert loaded.active_repair_proposal.source_tool_revision.id == revision.id
    assert is_nil(loaded.active_repair_proposal.candidate_tool_revision)
  end

  test "the tool a room offers follows its own generation", %{room: room, revision: revision} do
    _ = Patchbay.retire_tool_revision!(revision)

    published =
      Fixtures.revision_attributes(room.id)
      |> Map.merge(%{generation: 2, name: "uplift_current_skill_v2", status: :candidate})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()
      |> ToolPublisher.publish!()

    loaded = Patchbay.get_room_by_id!(room.id, load: :desired_tool_revision)

    assert loaded.desired_tool_generation == 2
    assert loaded.desired_tool_revision.id == published.id
  end

  defp create_verification!(attrs) do
    Ash.Changeset.for_create(Verification, :record_verification, attrs)
    |> Ash.create!()
  end

  defp visible_post_state(room) do
    %{
      "ui_revision" => room.ui_revision,
      "source" => %{"present" => true, "sha256" => room.source_sha256},
      "candidate" => %{
        "present" => is_binary(room.candidate_markdown),
        "sha256" => room.candidate_sha256
      }
    }
  end

  # Every room is created already offering its generation-1 tool.
  defp seeded_revision!(room) do
    Patchbay.list_tool_revisions!(query: [filter: [room_id: room.id, status: :desired], limit: 1])
    |> List.first()
  end
end
