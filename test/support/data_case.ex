defmodule SpreadSheetAi.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SpreadSheetAi.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SpreadSheetAi.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import SpreadSheetAi.DataCase
    end
  end

  setup tags do
    SpreadSheetAi.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SpreadSheetAi.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Registered last so it runs first: no sheet server outlives the sandbox.
    unless tags[:async], do: on_exit(&stop_sheet_servers/0)
  end

  @doc """
  Stops every sheet server. Sheet servers run under a global supervisor, so
  tests that start them must be `async: false` (they share the sandbox
  connection); ExUnit never runs those alongside async tests, so stopping
  all of them is safe.
  """
  def stop_sheet_servers do
    supervisor = SpreadSheetAi.Sheets.ServerSupervisor

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(supervisor, pid)
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
