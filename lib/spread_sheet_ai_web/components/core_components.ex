defmodule SpreadSheetAiWeb.CoreComponents do
  @moduledoc """
  Gettext helpers used by HEEx-rendered errors and form-field translation.

  Vue owns the SPA UI, so the stock `mix phx.new` components (flash, button,
  input, table, icon, theme toggle) are gone — they assumed daisyUI +
  Heroicons, which we dropped along with Phoenix's esbuild/tailwind pipeline.
  When a future feature reintroduces HEEx UI, re-add only the components it
  needs rather than wholesale-restoring the scaffold.
  """

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(SpreadSheetAiWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SpreadSheetAiWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
