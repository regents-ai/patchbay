defmodule Patchbay.Patchbay.ResourcesTest do
  use Patchbay.DataCase, async: false

  require Ash.Query

  alias Elixir.Patchbay.Patchbay

  alias Elixir.Patchbay.Patchbay.{
    DemoReset,
    Digest,
    Fixtures,
    Invocation,
    RoomEvent,
    ToolPublisher,
    ToolRevision,
    Verification,
    VerificationService
  }

  setup do
    room = Patchbay.create_seeded_room!()

    revision =
      Fixtures.revision_attributes(room.id)
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()

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
    assert_raise Ash.Error.Invalid, fn -> Patchbay.create_seeded_room!() end

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

    Patchbay.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
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

    Patchbay.observe_browser_session!(reset_session, %{
      desired_generation: revision.generation + 1,
      observed_generation: revision.generation + 1,
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    assert Patchbay.get_browser_session!(browser_session.id).disconnected_at

    Patchbay.observe_browser_session!(reset_session, %{
      desired_generation: revision.generation,
      observed_generation: revision.generation,
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    refute Patchbay.get_browser_session!(browser_session.id).disconnected_at
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
             "ui_revision" => 0,
             "source" => %{"present" => true, "sha256" => room.source_sha256},
             "candidate" => %{"present" => false, "sha256" => nil}
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
    other_room = insert_room!("other-room")

    other_revision =
      Fixtures.revision_attributes(other_room.id)
      |> Map.merge(%{generation: 1, status: :desired})
      |> Map.delete(:contract_sha256)
      |> Patchbay.create_tool_revision!()

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
        passed: false,
        checks: %{},
        expected_state: %{},
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

  test "verification success requires a complete verifier result", %{
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

    assert_raise Ash.Error.Invalid, fn ->
      create_verification!(%{
        room_id: room.id,
        invocation_id: invocation.id,
        passed: true,
        checks: %{},
        expected_state: %{},
        observed_state: %{}
      })
    end

    checks =
      Map.new(Elixir.Patchbay.Patchbay.PostconditionVerifier.required_checks(), &{&1, true})

    assert_raise Ash.Error.Invalid, fn ->
      create_verification!(%{
        room_id: room.id,
        invocation_id: invocation.id,
        passed: true,
        checks: checks,
        expected_state: %{"candidate" => %{"present" => false}},
        observed_state: %{"candidate" => %{"present" => true}}
      })
    end
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
        post_state: %{"candidate" => %{"present" => true}}
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

    Patchbay.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    verified =
      VerificationService.verify_invocation!(successful_invocation, %{
        post_state: %{
          candidate: %{
            present: true,
            sha256: room.candidate_sha256
          }
        }
      })

    assert verified.effective_status == :verified_success

    retried =
      VerificationService.verify_invocation!(successful_invocation, %{
        post_state: %{
          candidate: %{
            present: true,
            sha256: room.candidate_sha256
          },
          tool_contract_sha256: "caller-forged",
          browser_session_id: Ash.UUID.generate()
        }
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

    Patchbay.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
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
        post_state: %{candidate: %{present: true, sha256: room.candidate_sha256}}
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

    Patchbay.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())

    post_state = %{candidate: %{present: true, sha256: room.candidate_sha256}}
    result = VerificationService.derive_result(invocation, post_state)

    verification =
      create_verification!(%{
        room_id: room.id,
        invocation_id: invocation.id,
        checks: result.checks,
        passed: result.passed,
        failure_code: result.failure_code,
        expected_state: result.expected_state,
        observed_state: result.observed_state
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

    Patchbay.observe_browser_session!(browser_session, %{
      observed_generation: revision.generation,
      observed_contracts: %{revision.name => revision.contract_sha256}
    })

    room = Patchbay.apply_candidate!(room, Fixtures.improved_markdown())
    Patchbay.disconnect_browser_session!(browser_session, %{disconnected_at: DateTime.utc_now()})

    verified =
      VerificationService.verify_invocation!(invocation, %{
        post_state: %{
          candidate: %{present: true, sha256: room.candidate_sha256},
          tool_contract_sha256: revision.contract_sha256,
          browser_session_id: browser_session.id
        }
      })

    assert verified.effective_status == :verified_failure
    assert verified.failure_code == :STALE_BROWSER_SESSION
  end

  test "proposal publication requires approval and a passed canary", %{
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
        canary_result: %{"passed" => false},
        risk_notes: [],
        model: "fixture",
        model_response_id: "fixture-response",
        prompt_version: "v1",
        input_sha256: Digest.sha256("proposal")
      })

    assert_raise Ash.Error.Invalid, fn -> Patchbay.publish_repair_proposal!(proposal) end

    canary_checks = %{
      "adapter_allowlisted" => true,
      "postcondition_allowlisted" => true,
      "candidate_present" => true,
      "source_unchanged" => true,
      "candidate_digest_changed" => true,
      "frontmatter_valid" => true,
      "identity_preserved" => true,
      "output_contract_valid" => true,
      "ui_revision_advanced" => true
    }

    proposal =
      Patchbay.mark_canary_passed!(proposal, %{
        canary_result: %{"passed" => true, "checks" => canary_checks}
      })

    proposal = Patchbay.approve_repair_proposal!(proposal, "founder")
    assert Patchbay.publish_repair_proposal!(proposal).status == :published
  end

  test "unknown reset slugs return not found", %{room: _room} do
    assert_raise Ash.Error.Query.NotFound, fn -> DemoReset.reset!("does-not-exist") end
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
        canary_result: %{"passed" => true},
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
      Patchbay.observe_browser_session!(browser_session, %{
        observed_generation: revision.generation,
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

  defp insert_room!(slug) do
    attrs =
      Fixtures.room_attributes()
      |> Map.put(:id, Ecto.UUID.dump!(Ash.UUID.generate()))
      |> Map.put(:slug, slug)
      |> Map.put(:status, "ready")
      |> Map.put(:goal_kind, "skill_uplift")

    {1, _} = Repo.insert_all("rooms", [attrs])
    Patchbay.get_room_by_slug!(slug)
  end

  defp create_verification!(attrs) do
    Ash.Changeset.for_create(Verification, :record_verification, attrs)
    |> Ash.create!()
  end
end
