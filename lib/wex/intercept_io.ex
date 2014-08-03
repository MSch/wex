defmodule Wex.InterceptIO do
  @moduledoc """
  This module is a blatant ripoff of Elixirs StringIO module.

  We act as an IO device, but we forward output on to the
  websocket.

  We also request input from the browser when reads are issued.
  """

  use GenServer

  def start_link(args) do
    :gen_server.start_link(__MODULE__, args, [])
  end

  ## callbacks

  def init({device, ws}) do
    {:ok, %{device: device, ws: ws}}
  end

  def handle_info({:io_request, from, reply_as, req}, s) do
    {:noreply, io_request(from, reply_as, req, s)}
  end

  def handle_info(msg, s) do
    super(msg, s)
  end

  defp io_request(from, reply_as, req, s) do
    {reply, s} = io_request(req, s)
    io_reply(from, reply_as, to_reply(reply))
    s
  end

  defp io_request({:put_chars, chars}, %{ws: ws, device: device} = s) do
    send ws, {device,  IO.chardata_to_string(chars)}
    {:ok, s}
  end

  defp io_request({:put_chars, m, f, as}, s) do
    chars = apply(m, f, as)
    io_request({:put_chars, chars}, s)
  end

  defp io_request({:put_chars, _encoding, chars}, s) do
    io_request({:put_chars, chars}, s)
  end

  defp io_request({:put_chars, _encoding, mod, func, args}, s) do
    io_request({:put_chars, mod, func, args}, s)
  end

  defp io_request({:get_chars, prompt, n}, s) when n >= 0 do
    io_request({:get_chars, :latin1, prompt, n}, s)
  end

  defp io_request({:get_chars, encoding, prompt, n}, s) when n >= 0 do
    get_chars(encoding, prompt, n, s)
  end

  defp io_request({:get_line, prompt}, s) do
    io_request({:get_line, :latin1, prompt}, s)
  end

  defp io_request({:get_line, encoding, prompt}, s) do
    get_line(encoding, prompt, s)
  end

  defp io_request({:get_until, prompt, mod, fun, args}, s) do
    io_request({:get_until, :latin1, prompt, mod, fun, args}, s)
  end

  defp io_request({:get_until, encoding, prompt, mod, fun, args}, s) do
    get_until(encoding, prompt, mod, fun, args, s)
  end

  defp io_request({:get_password, encoding}, s) do
    get_line(encoding, "", s)
  end

  defp io_request({:setopts, _opts}, s) do
    {{:error, :enotsup}, s}
  end

  defp io_request(:getopts, s) do
    {{:ok, [binary: true, encoding: :unicode]}, s}
  end

  defp io_request({:get_geometry, :columns}, s) do
    {{:error, :enotsup}, s}
  end

  defp io_request({:get_geometry, :rows}, s) do
    {{:error, :enotsup}, s}
  end

  defp io_request({:requests, reqs}, s) do
    io_requests(reqs, {:ok, s})
  end

  defp io_request(_, s) do
    {{:error, :request}, s}
  end

  ## get_chars

  defp get_chars(encoding, prompt, n,
                 %{input: input, output: output, capture_prompt: capture_prompt} = s) do
    case do_get_chars(input, encoding, n) do
      {:error, _} = error ->
        {error, s}
      {result, input} ->
        if capture_prompt do
          output = << output :: binary, IO.chardata_to_string(prompt) :: binary >>
        end

        {result, %{s | input: input, output: output}}
    end
  end

  defp do_get_chars("", _encoding, _n) do
    {:eof, ""}
  end

  defp do_get_chars(input, :latin1, n) when byte_size(input) < n do
    {input, ""}
  end

  defp do_get_chars(input, :latin1, n) do
    <<chars :: binary-size(n), rest :: binary>> = input
    {chars, rest}
  end

  defp do_get_chars(input, encoding, n) do
    try do
      case :file_io_server.count_and_find(input, n, encoding) do
        {buf_count, split_pos} when buf_count < n or split_pos == :none ->
          {input, ""}
        {_buf_count, split_pos} ->
          <<chars :: binary-size(split_pos), rest :: binary>> = input
          {chars, rest}
      end
    catch
      :exit, :invalid_unicode ->
        {:error, :invalid_unicode}
    end
  end

  ## get_line

  defp get_line(encoding, prompt,
                %{input: input, output: output, capture_prompt: capture_prompt} = s) do
    case :unicode.characters_to_list(input, encoding) do
      {:error, _, _} ->
        {{:error, :collect_line}, s}
      {:incomplete, _, _} ->
        {{:error, :collect_line}, s}
      chars ->
        {result, input} = do_get_line(chars, encoding)

        if capture_prompt do
          output = << output :: binary, IO.chardata_to_string(prompt) :: binary >>
        end

        {result, %{s | input: input, output: output}}
    end
  end

  defp do_get_line('', _encoding) do
    {:eof, ""}
  end

  defp do_get_line(chars, encoding) do
    {line, rest} = collect_line(chars)
    {:unicode.characters_to_binary(line, encoding),
      :unicode.characters_to_binary(rest, encoding)}
  end

  ## get_until

  defp get_until(encoding, prompt, mod, fun, args,
                 %{input: input, output: output, capture_prompt: capture_prompt} = s) do
    case :unicode.characters_to_list(input, encoding) do
      {:error, _, _} ->
        {:error, s}
      {:incomplete, _, _} ->
        {:error, s}
      chars ->
        {result, input, count} = do_get_until(chars, encoding, mod, fun, args)

        if capture_prompt do
          output = << output :: binary, :binary.copy(IO.chardata_to_string(prompt), count) :: binary >>
        end

        input =
          case input do
            :eof -> ""
            _ -> :unicode.characters_to_binary(input, encoding)
          end

        {result, %{s | input: input, output: output}}
    end
  end

  defp do_get_until(chars, encoding, mod, fun, args, continuation \\ [], count \\ 0)

  defp do_get_until('', encoding, mod, fun, args, continuation, count) do
    case apply(mod, fun, [continuation, :eof | args]) do
      {:done, result, rest} ->
        {result, rest, count + 1}
      {:more, next_continuation} ->
        do_get_until('', encoding, mod, fun, args, next_continuation, count + 1)
    end
  end

  defp do_get_until(chars, encoding, mod, fun, args, continuation, count) do
    {line, rest} = collect_line(chars)

    case apply(mod, fun, [continuation, line | args]) do
      {:done, result, rest1} ->
        unless rest1 == :eof do
          rest = rest1 ++ rest
        end
        {result, rest, count + 1}
      {:more, next_continuation} ->
        do_get_until(rest, encoding, mod, fun, args, next_continuation, count + 1)
    end
  end

  ## io_requests

  defp io_requests([r|rs], {:ok, s}) do
    io_requests(rs, io_request(r, s))
  end

  defp io_requests(_, result) do
    result
  end

  ## helpers

  defp collect_line(chars) do
    collect_line(chars, [])
  end

  defp collect_line([], stack) do
    {:lists.reverse(stack), []}
  end

  defp collect_line([?\r, ?\n | rest], stack) do
    {:lists.reverse([?\n|stack]), rest}
  end

  defp collect_line([?\n | rest], stack) do
    {:lists.reverse([?\n|stack]), rest}
  end

  defp collect_line([h|t], stack) do
    collect_line(t, [h|stack])
  end

  defp io_reply(from, reply_as, reply) do
    send from, {:io_reply, reply_as, reply}
  end

  defp to_reply(list) when is_list(list), do: IO.chardata_to_string(list)
  defp to_reply(other), do: other

end