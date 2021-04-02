defmodule CobolToElixir.Parser do
  alias CobolToElixir.Parsed
  alias CobolToElixir.Parsed.Variable

  require Logger

  def parse(tokenized) do
    divisions = parse_divisions(tokenized)

    parsed =
      Enum.reduce(divisions, %Parsed{}, fn {name, division}, parsed ->
        parse_division(name, division, parsed)
      end)

    {:ok, parsed}
  end

  def parse_divisions(tokenized) do
    do_parse_divisions(tokenized, nil, %{})
  end

  defp do_parse_divisions([:source_format_free | tail], nil, %{}),
    do: do_parse_divisions(tail, nil, %{})

  defp do_parse_divisions([{:division, division} | tail], _current, divisions),
    do: do_parse_divisions(tail, division, Map.put_new(divisions, division, []))

  defp do_parse_divisions([other | tail], current, divisions),
    do: do_parse_divisions(tail, current, update_in(divisions, [current], &(&1 ++ [other])))

  defp do_parse_divisions([], _, divisions), do: divisions

  def parse_sections(tokenized) do
    do_parse_sections(tokenized, nil, %{})
  end

  defp do_parse_sections([{:section, section} | tail], _current, sections),
    do: do_parse_sections(tail, section, Map.put_new(sections, section, []))

  defp do_parse_sections([other | tail], current, sections),
    do: do_parse_sections(tail, current, update_in(sections, [current], &(&1 ++ [other])))

  defp do_parse_sections([], _, sections), do: sections

  defp parse_division("IDENTIFICATION", identification, %Parsed{} = parsed) do
    if is_nil(identification), do: raise("No identification division")
    {program_id, identification} = Keyword.pop!(identification, :program_id)
    {author, identification} = Keyword.pop(identification, :author)
    {date_written, identification} = Keyword.pop(identification, :date_written)

    if identification != [] do
      Logger.warn("Unparsed identification: #{inspect(Keyword.keys(identification))}")
    end

    %Parsed{
      parsed
      | program_id: program_id,
        author: author,
        date_written: date_written
    }
  end

  defp parse_division("DATA", nil, parsed), do: parsed

  defp parse_division("DATA", data, parsed) do
    data
    |> parse_sections()
    |> Enum.reduce(parsed, fn {name, section}, parsed ->
      parse_data_section(name, section, parsed)
    end)
  end

  defp parse_division("PROCEDURE", procedure, %Parsed{} = parsed) do
    %Parsed{parsed | procedure: procedure}
  end

  defp parse_division(name, _contents, parsed) do
    Logger.warn("No parser for division #{name}")
    parsed
  end

  defp parse_data_section("FILE", [], parsed), do: parsed
  defp parse_data_section("WORKING-STORAGE", [], parsed), do: parsed

  defp parse_data_section("WORKING-STORAGE", contents, parsed) do
    all_variables =
      contents
      |> Enum.filter(&(elem(&1, 0) == :variable_line))
      |> Enum.map(fn {:variable_line, line} ->
        variable_line_to_variable(line)
      end)

    variable_map =
      all_variables
      |> Enum.map(fn %Variable{name: name} = var -> {name, var} end)
      |> Enum.into(%{})

    %Parsed{parsed | variables: all_variables, variable_map: variable_map}
  end

  defp variable_line_to_variable([depth, name | rest] = line) do
    {pic, rest} = parse_var_field(rest, :pic)
    pic = parse_pic(pic)
    {value, rest} = parse_var_field(rest, :value)
    {constant, rest} = parse_var_field(rest, :constant)

    if rest != [] do
      Logger.warn("Variable contained unexpected values: #{inspect(rest)}. Full variable: #{inspect(line)}")
    end

    value =
      case pic do
        {:str, _, length} -> value |> String.slice(0..(length - 1)) |> String.pad_trailing(length)
        _ -> IO.inspect(value, label: "other")
      end

    %Variable{
      depth: depth,
      name: name,
      type:
        if is_nil(pic) and is_nil(constant) and is_nil(value) do
          :map
        else
          :single
        end,
      pic: pic,
      value: value || constant,
      constant: !is_nil(constant)
    }
  end

  defp parse_var_field([field, pic | rest], field), do: {pic, rest}
  defp parse_var_field(rest, _), do: {nil, rest}

  defp parse_pic(nil), do: nil

  defp parse_pic(pic) do
    pic =
      case Regex.run(~r/^([9|X])\((\d)\)/, pic) do
        [_, type, count] -> String.duplicate(type, String.to_integer(count))
        nil -> pic
      end

    split = String.split(pic, "", trim: true)

    cond do
      Enum.all?(split, &(&1 == "X")) -> {:str, pic, String.length(pic)}
      Enum.all?(split, &(&1 == "9")) -> {:int, pic, String.length(pic)}
      true -> {:other, pic}
    end
  end
end
