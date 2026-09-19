# Dev helpers for exercising the sheet grid against the real backend.
#
# Load from an IEx session attached to the running server, so the helpers
# share its sheet processes and PubSub:
#
#     iex -S mix phx.server
#     iex> c "dev/sheets.exs"
#     iex> id = Dev.Sheets.big_sheet("alice@example.com")
#     iex> Dev.Sheets.simulate_edits(id, "bob@example.com")
#
# Not compiled into the app. It stands in for the frontend mock's big sheet
# and "simulate remote user" control (docs/frontend-plan.md §9).
defmodule Dev.Sheets do
  alias SpreadSheetAi.Accounts
  alias SpreadSheetAi.Sheets
  alias SpreadSheetAi.Sheets.Actor

  @types ~w(number text number date boolean)
  @chunk 250

  @doc "Creates a `rows` × `cols` sheet of mixed column types owned by `email`. Returns its id."
  def big_sheet(email, rows \\ 1000, cols \\ 30) do
    owner = user!(email)
    columns = for i <- 1..(cols - 1), do: %{"name" => "C#{i}", "column_type" => type(i)}

    {:ok, sheet} =
      Sheets.create_sheet(
        %{"name" => "Big sheet #{rows}×#{cols}", "columns" => columns},
        owner
      )

    actor = Actor.user(owner)

    1..rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      new_rows =
        for r <- chunk do
          values =
            Map.new(columns, fn %{"name" => name, "column_type" => t} -> {name, value(t, r)} end)

          %{"label" => "Row #{r}", "values" => values}
        end

      {:ok, _version, _applied} =
        Sheets.apply_named(sheet.id, %{"type" => "add_rows", "rows" => new_rows}, actor)
    end)

    sheet.id
  end

  @doc """
  Sends `count` random single-cell `set_cells` ops as `email`, one every
  `every_ms`, from a background task. Watch the grid for cues.
  """
  def simulate_edits(sheet_id, email, count \\ 50, every_ms \\ 400) do
    actor = Actor.user(user!(email))

    Task.start(fn ->
      for _ <- 1..count do
        {:ok, state} = Sheets.snapshot(sheet_id)

        column =
          state.columns_by_id |> Map.values() |> Enum.reject(& &1.is_label) |> Enum.random()

        row_id = Enum.random(state.row_order)
        value = value(column.column_type, :rand.uniform(10_000))

        op = %{
          "type" => "set_cells",
          "cells" => [%{"row_id" => row_id, "column_id" => column.id, "value" => value}]
        }

        {:ok, parsed} = Sheets.Op.parse(op)
        Sheets.apply_op(sheet_id, parsed, actor)
        Process.sleep(every_ms)
      end
    end)
  end

  defp user!(email) do
    Accounts.get_user_by_email(email) || raise "no user with email #{email}"
  end

  defp type(i), do: Enum.at(@types, rem(i, length(@types)))

  defp value("number", n), do: rem(n * 17, 100_000) / 4
  defp value("text", n), do: "Item #{n}"
  defp value("boolean", n), do: rem(n, 3) == 0
  defp value("date", n), do: Date.add(~D[2026-01-01], rem(n, 365)) |> Date.to_iso8601()
end
