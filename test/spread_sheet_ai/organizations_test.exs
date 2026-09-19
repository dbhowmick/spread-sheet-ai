defmodule SpreadSheetAi.OrganizationsTest do
  use SpreadSheetAi.DataCase, async: true

  alias SpreadSheetAi.Accounts
  alias SpreadSheetAi.AuthFixtures
  alias SpreadSheetAi.Organizations

  describe "create_organization_for_user/3" do
    test "creates org + owner Member, and updates the session" do
      user = AuthFixtures.verified_user_fixture()
      {:ok, %{session: session}} = Accounts.create_session(user, nil, %{})

      assert {:ok, %{organization: org, member: member, session: updated_session}} =
               Organizations.create_organization_for_user(user, session, %{name: "Acme Inc."})

      assert org.name == "Acme Inc."
      assert org.slug == "acme-inc"
      assert member.role == "owner"
      assert member.status == "active"
      assert member.user_id == user.id
      assert updated_session.current_member_id == member.id
    end

    test "auto-suffixes a colliding slug" do
      user = AuthFixtures.verified_user_fixture()
      _ = AuthFixtures.organization_fixture(user, name: "Acme")

      user2 = AuthFixtures.verified_user_fixture()
      {:ok, %{session: session}} = Accounts.create_session(user2, nil, %{})

      assert {:ok, %{organization: org}} =
               Organizations.create_organization_for_user(user2, session, %{name: "Acme"})

      assert org.slug == "acme-2"
    end

    test "rejects a second active membership for the same user (single mode)" do
      %{user: user, session: session} = AuthFixtures.organization_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Organizations.create_organization_for_user(user, session, %{name: "Second"})

      assert %{user_id: [_]} = errors_on(changeset)
    end
  end

  describe "list_memberships_for_user/1" do
    test "returns only the user's active memberships, with :organization preloaded" do
      %{user: user, member: member, organization: org} = AuthFixtures.organization_fixture()
      _other = AuthFixtures.organization_fixture()

      assert [membership] = Organizations.list_memberships_for_user(user.id)
      assert membership.id == member.id
      assert membership.organization.id == org.id
    end
  end

  describe "verify_member_for_user/2" do
    test "returns the member when owned by the user" do
      %{user: user, member: member} = AuthFixtures.organization_fixture()
      assert {:ok, found} = Organizations.verify_member_for_user(user, member.id)
      assert found.id == member.id
    end

    test "returns :forbidden when the member belongs to a different user" do
      %{member: member} = AuthFixtures.organization_fixture()
      other_user = AuthFixtures.verified_user_fixture()
      assert {:error, :forbidden} = Organizations.verify_member_for_user(other_user, member.id)
    end

    test "returns :not_found for a missing member id" do
      user = AuthFixtures.verified_user_fixture()

      assert {:error, :not_found} =
               Organizations.verify_member_for_user(user, Ecto.UUID.generate())
    end
  end
end
