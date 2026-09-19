defmodule SpreadSheetAiWeb.SheetJSON do
  @moduledoc """
  Contract serializers for sheets (contract §2 and §5). Pure: shared by
  `SpreadSheetAiWeb.Api.SheetController` and `SpreadSheetAiWeb.SheetChannel`.
  """

  alias SpreadSheetAi.Accounts.User
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.{Actor, State}

  @doc "A full `Sheet` snapshot (§2.6). Row `cells` include the label."
  @spec sheet(State.t()) :: map()
  def sheet(%State{} = state) do
    %{
      id: state.id,
      name: state.name,
      owner: state.owner,
      version: state.version,
      columns: Enum.map(State.columns(state), &column/1),
      rows: Enum.map(State.rows(state), &%{id: &1.id, cells: State.row_cells(state, &1)}),
      inserted_at: state.inserted_at,
      updated_at: state.updated_at
    }
  end

  @doc "A `SheetSummary` (§2.5), from `SpreadSheetAi.Sheets.list_sheets/0`."
  @spec summary(Sheets.summary()) :: map()
  def summary(summary) do
    Map.take(summary, [
      :id,
      :name,
      :owner,
      :row_count,
      :column_count,
      :version,
      :inserted_at,
      :updated_at
    ])
  end

  @doc "The `op_applied` push (§5.3), from a sheet's `{:op_applied, event}`."
  @spec op_applied(map()) :: map()
  def op_applied(%{version: version, applied_op: op, actor: actor, client_op_id: client_op_id}) do
    %{version: version, op: op, actor: actor(actor), client_op_id: client_op_id}
  end

  @doc "An `Actor` (§2.7)."
  @spec actor(Actor.t()) :: map()
  def actor(%Actor{type: :user, user: user}), do: %{type: "user", user: user_ref(user)}

  def actor(%Actor{type: :agent} = actor) do
    %{
      type: "agent",
      conversation_id: actor.conversation_id,
      conversation_title: actor.conversation_title
    }
  end

  @doc "A `UserRef` (§2.1): the display name falls back to the email."
  @spec user_ref(User.t()) :: map()
  def user_ref(%User{} = user), do: %{id: user.id, display_name: User.display_name(user)}

  @doc "The `participants` push (§5.3): the current viewers, by name."
  @spec participants([map()]) :: map()
  def participants(user_refs), do: %{users: Enum.sort_by(user_refs, &{&1.display_name, &1.id})}

  defp column(column) do
    %{
      id: column.id,
      name: column.name,
      column_type: column.column_type,
      is_label: column.is_label
    }
  end
end
