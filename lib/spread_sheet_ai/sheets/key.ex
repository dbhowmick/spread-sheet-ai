defmodule SpreadSheetAi.Sheets.Key do
  @moduledoc """
  Normalizes column names and row labels for uniqueness checks: trimmed and
  case-insensitive (contract §6). The `*_key` columns and the engine's
  in-memory indexes both use this, so they always agree.
  """

  @spec normalize(String.t()) :: String.t()
  def normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  @doc "Puts the normalized value of `field` into `key_field` when `field` changes."
  @spec put_key(Ecto.Changeset.t(), atom(), atom()) :: Ecto.Changeset.t()
  def put_key(changeset, field, key_field) do
    case Ecto.Changeset.get_change(changeset, field) do
      value when is_binary(value) ->
        Ecto.Changeset.put_change(changeset, key_field, normalize(value))

      _ ->
        changeset
    end
  end
end
