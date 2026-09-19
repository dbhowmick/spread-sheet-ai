defmodule SpreadSheetAiWeb.Layouts do
  @moduledoc """
  Holds the root HTML layout that wraps every browser response.

  Since the SPA owns all in-page UI (flash, navigation, theme, etc.), this
  module is intentionally minimal — just the `root` template that ships the
  SPA shell. Add an `app/1` layout here if a future feature renders HEEx
  surfaces alongside the SPA.
  """
  use SpreadSheetAiWeb, :html

  embed_templates "layouts/*"
end
