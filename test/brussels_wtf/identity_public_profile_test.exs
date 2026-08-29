defmodule BrusselsWtf.IdentityPublicProfileTest do
  use BrusselsWtf.DataCase, async: false

  alias BrusselsWtf.Identity
  alias BrusselsWtf.Identity.PublicProfile
  alias BrusselsWtf.Test.PublicProfileFixture

  setup do
    company = PublicProfileFixture.company!()
    {:ok, company: company}
  end

  test "company profiles require an exact canonical CBE entity and return a closed citation", %{
    company: company
  } do
    assert {:ok, profile} = Identity.get_public_company_profile("0123456749")

    assert profile == %PublicProfile.Company{
             entity_id: company.id,
             registered_name: "Public Example ASBL",
             enterprise_number: "0123456749",
             status: :active,
             cbe: %PublicProfile.CbeCitation{
               published_on: ~D[2026-08-29],
               sha256: String.duplicate("b", 64)
             },
             relationships: []
           }

    rendered = inspect(profile)
    assert rendered =~ company.id
    refute rendered =~ "PRIVATE-CBE-RELEASE-KEY"
    refute rendered =~ "trading"
    refute rendered =~ "establishment"

    assert {:error, :not_found} = Identity.get_public_company_profile("0123.456.749")
    assert {:error, :not_found} = Identity.get_public_company_profile("0123456748")
    assert {:error, :not_found} = Identity.get_public_company_profile("not-a-number")
  end

  test "company profiles fail closed when their CBE release checksum is invalid" do
    PublicProfileFixture.company!(%{
      enterprise_number: "0202239951",
      registered_name: "Invalid Release SA",
      sha256: "not-a-checksum"
    })

    assert {:error, :not_found} = Identity.get_public_company_profile("0202239951")
  end

  test "only active canonical people with a current automatically verified safe relationship publish" do
    fixture = PublicProfileFixture.load!()

    %{person: person, fact: fact} =
      PublicProfileFixture.publish_person!(fixture, "Alex Public", 51)

    assert fact.verification_status == :verified
    assert {:ok, profile} = Identity.get_public_person_profile(person.id)

    assert %PublicProfile.Person{
             id: id,
             legal_name: "Alex Public",
             relationships: [%BrusselsWtf.Identity.PublicRelationship{} = relationship]
           } = profile

    assert id == person.id
    assert relationship.kind == :public_mandate
    assert relationship.effective_from == ~D[2025-01-01]

    rendered = inspect(profile)
    refute rendered =~ "PRIVATE"
    refute rendered =~ fact.verification_generation
  end

  test "a private retired source stays private while a previously public source redirects" do
    fixture = PublicProfileFixture.load!()
    %{person: target} = PublicProfileFixture.publish_person!(fixture, "Alex Public", 52)
    %{person: prior_public} = PublicProfileFixture.publish_person!(fixture, "Prior Public", 53)

    private_source = record_private_person!("PRIVATE RETIRED SOURCE")
    actor = %BrusselsWtf.Review.Actor{id: "rico", role: :reviewer}

    Identity.merge_people!(private_source.id, target.id, "PRIVATE MERGE NOTE", actor)
    Identity.merge_people!(prior_public.id, target.id, "PUBLIC MERGE NOTE", actor)

    assert {:error, :not_found} = Identity.get_public_person_profile(private_source.id)

    assert {:redirect, %PublicProfile.Redirect{kind: :person, target_id: target_id}} =
             Identity.get_public_person_profile(prior_public.id)

    assert target_id == target.id
  end

  test "unknown, invalid UUID, and private-only person profiles fail closed" do
    person = record_private_person!("PRIVATE PERSON NAME")

    assert {:error, :not_found} = Identity.get_public_person_profile(person.id)
    assert {:error, :not_found} = Identity.get_public_person_profile(Ecto.UUID.generate())
    assert {:error, :not_found} = Identity.get_public_person_profile("not-a-uuid")
  end

  defp record_private_person!(legal_name) do
    Identity.record_person!(%{
      legal_name: legal_name,
      explicit_identifier: "private-#{System.unique_integer([:positive])}",
      resolution_basis: :explicit_identifier,
      corroborating_facts: %{"private_address" => "PRIVATE HOME ADDRESS"}
    })
  end
end
