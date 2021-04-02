defmodule CobolToElixirCase do
  import ExUnit.CaptureIO

  require ExUnit.Assertions

  def execute_cobol_code(cobol, input \\ []) do
    tmp_folder = Path.relative_to_cwd("test/temp/#{Enum.random(1000..1_000_000_000_000)}")

    try do
      File.mkdir_p!(tmp_folder)
      cobol_path = Path.join(tmp_folder, "cobol.cob")
      cobol_executable_path = Path.join(tmp_folder, "cobol")
      File.write(cobol_path, cobol)

      case System.cmd("cobc", ["-x", "-o", cobol_executable_path, cobol_path], stderr_to_stdout: true) do
        {"", 0} -> :ok
        {output, 1} -> raise "Error compiling cobol:\n#{output}"
      end

      port = Port.open({:spawn, "#{tmp_folder}/cobol"}, [:binary, :exit_status, :stderr_to_stdout])

      send_cobol_input(port, input)

      # :timer.sleep(1000)
      # Port.close(port)
      output = get_cobol_output(port) |> Enum.reverse() |> Enum.join("")
      # {output, 0} = System.cmd("./#{tmp_folder}/cobol", [], stderr_to_stdout: true)
      output
    after
      File.rm_rf!(tmp_folder)
    end
  end

  defp get_cobol_output(port, acc \\ []) do
    receive do
      {^port, {:data, output}} -> get_cobol_output(port, [output | acc])
      {^port, {:closed}} -> acc
      {^port, {:exit_status, 0}} -> acc
      other -> raise "got unexpected port response: #{inspect(other)}"
    end
  end

  defp send_cobol_input(_port, []), do: :ok

  defp send_cobol_input(port, [{timeout, input} | tail]) do
    :timer.sleep(timeout)
    Port.command(port, "#{input}\n")
    send_cobol_input(port, tail)
  end

  def execute_elixir_code(str, module, input) do
    Code.compile_string(str)

    {:module, ^module} = Code.ensure_loaded(module)

    io =
      capture_io(fn ->
        Enum.each(input, &send(self(), {:input, elem(&1, 1)}))
        apply(module, :main, [])
      end)

    :code.delete(module)
    :code.purge(module)

    io
  end

  def assert_output_equal(cobol_text, module, output \\ "", input \\ []) do
    cobol_output = execute_cobol_code(cobol_text, input)
    {:ok, elixir_text} = CobolToElixir.convert(cobol_text, accept_via_message: true)
    elixir_output = execute_elixir_code(elixir_text, module, input)
    ExUnit.Assertions.assert(cobol_output == elixir_output)

    if !is_nil(output) do
      ExUnit.Assertions.assert(cobol_output == output)
    end
  end
end
