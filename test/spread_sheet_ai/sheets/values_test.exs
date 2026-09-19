defmodule SpreadSheetAi.Sheets.ValuesTest do
  use ExUnit.Case, async: true

  alias SpreadSheetAi.Sheets.Values

  describe "cast/2" do
    test "nil is an empty cell in every type" do
      for type <- ~w(text number boolean date), do: assert(Values.cast(type, nil) == {:ok, nil})
    end

    test "valid values" do
      for {type, input, stored} <- [
            {"text", "Revenue", "Revenue"},
            {"text", "  padded  ", "  padded  "},
            {"text", "", nil},
            {"number", 1200, 1200},
            {"number", -12.5, -12.5},
            {"number", 12.0, 12},
            {"number", 9_007_199_254_740_992, 9_007_199_254_740_992},
            {"boolean", true, true},
            {"boolean", false, false},
            {"date", "2026-09-20", "2026-09-20"},
            {"date", "2024-02-29", "2024-02-29"}
          ] do
        assert Values.cast(type, input) == {:ok, stored}, "#{type} #{inspect(input)}"
      end
    end

    test "invalid values" do
      for {type, input} <- [
            {"text", 12},
            {"text", true},
            {"number", "12"},
            {"number", true},
            {"number", 9_007_199_254_740_993},
            {"boolean", "true"},
            {"boolean", 1},
            {"date", "2026-02-30"},
            {"date", "20260920"},
            {"date", "+2026-09-20"},
            {"date", "2026-09-20T10:00:00Z"},
            {"date", 20_260_920},
            {"currency", 12}
          ] do
        assert Values.cast(type, input) == {:error, :invalid_value}, "#{type} #{inspect(input)}"
      end
    end
  end

  describe "convert/3" do
    test "succeeds where the rules allow" do
      for {from, to, input, output} <- [
            {"number", "number", 12, 12},
            {"number", "text", 1200, "1200"},
            {"number", "text", 12.5, "12.5"},
            {"boolean", "text", true, "true"},
            {"date", "text", "2026-09-20", "2026-09-20"},
            {"text", "number", " 1200 ", 1200},
            {"text", "number", "12.5", 12.5},
            {"text", "number", "1e3", 1000},
            {"text", "date", "2026-09-20", "2026-09-20"},
            {"text", "boolean", "TRUE", true},
            {"text", "boolean", " false ", false},
            {"text", "number", "   ", nil},
            {"text", "date", " ", nil},
            {"boolean", "number", true, 1},
            {"boolean", "number", false, 0},
            {"number", "boolean", 1, true},
            {"number", "boolean", 0, false},
            {"number", "date", nil, nil}
          ] do
        assert Values.convert(from, to, input) == {:ok, output},
               "#{from} → #{to} #{inspect(input)}"
      end
    end

    test "fails where the rules don't allow" do
      for {from, to, input} <- [
            {"text", "number", "12 apples"},
            {"text", "number", "1,200"},
            {"text", "date", "20/09/2026"},
            {"text", "boolean", "yes"},
            {"number", "boolean", 2},
            {"number", "date", 20_260_920},
            {"date", "number", "2026-09-20"},
            {"boolean", "date", true},
            {"date", "boolean", "2026-09-20"}
          ] do
        assert Values.convert(from, to, input) == :error, "#{from} → #{to} #{inspect(input)}"
      end
    end
  end
end
