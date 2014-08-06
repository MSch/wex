# Total copy of IEx version. We needed different
# behanvior when completing (for example) Enum.each. IEx
# returns list containing just "each/2", while we
# want parameter list

defmodule Wex.Utility.Autocomplete do
  @moduledoc false

  require Logger

  def expand("") do
    expand_import("")
  end

  def expand(expr) do
    expr |> String.to_char_list |> Enum.reverse |> _expand
  end

  def _expand([h|t]=expr) do
    cond do
      h === ?. and t != []->
        expand_dot(reduce(t))
      h === ?: ->
        expand_erlang_modules
      identifier?(h) ->
        expand_expr(reduce(expr))
      (h == ?/) and t != [] and identifier?(hd(t)) ->
        expand_expr(reduce(t))
      h in '(+[' ->
        expand('')
      true ->
        no()
    end
  end

  defp identifier?(h) do
    (h in ?a..?z) or (h in ?A..?Z) or (h in ?0..?9) or h in [?_, ??, ?!]
  end

  defp expand_dot(expr) do
    case Code.string_to_quoted expr do
      {:ok, atom} when is_atom(atom) ->
        expand_call(atom, "")
      {:ok, {:__aliases__, _, list}} ->
        expand_elixir_modules(list, "")
      _ ->
        no()
    end
  end

  defp expand_expr(expr) do
    case Code.string_to_quoted expr do
      {:ok, atom} when is_atom(atom) ->
        expand_erlang_modules Atom.to_string(atom)
      {:ok, {atom, _, nil}} when is_atom(atom) ->
        expand_import Atom.to_string(atom)
      {:ok, {:__aliases__, _, [root]}} ->
        expand_elixir_modules [], Atom.to_string(root)
      {:ok, {:__aliases__, _, [h|_] = list}} when is_atom(h) ->
        hint = Atom.to_string(List.last(list))
        list = Enum.take(list, length(list) - 1)
        expand_elixir_modules list, hint
      {:ok, {{:., _, [mod, fun]}, _, []}} when is_atom(fun) ->
        expand_call mod, Atom.to_string(fun)
      _ ->
        no()
    end
  end

  defp reduce(expr) do
    last_token(Enum.reverse(expr), [' ', '(', '[', '+', '-'])
  end

  defp last_token(s, []) do
    s
  end

  defp last_token(s, [h|t]) do
    last_token(List.last(:string.tokens(s, h)), t)
  end

  defp yes(hint, entries) do
    {:yes, hint, entries}
  end

  defp no do
    {:no, "", []}
  end

  ## Formatting

  defp format_expansion([], _) do
    no()
  end

  defp format_expansion([uniq], hint) do
    Logger.info inspect uniq
    Logger.info inspect hint
    hint = to_hint(uniq, hint)
    Logger.info inspect hint
    uniq = if hint == "", do: to_uniq_entries(uniq), else: []
    yes(hint, uniq)
  end

  defp format_expansion([first|_]=entries, hint) do
    binary = Enum.map(entries, &(&1.name))
    length = byte_size(hint)
    prefix = :binary.longest_common_prefix(binary)
    Logger.info "hint = #{inspect hint}"
    Logger.info "prefix = #{inspect prefix}"

    if prefix in [0, length] do
      Logger.info inspect entries
      entries = Enum.map(entries, fn e ->
        %{ label: e.name, value: String.slice(e.name, prefix..-1) }
      end)
      yes("", entries)
    else
      yes(:binary.part(first.name, prefix, length-prefix), [])
    end
  end

  ## Root Modules

  defp root_modules do
    Enum.reduce :code.all_loaded, [], fn {m, _}, acc ->
      mod = Atom.to_string(m)
      case mod do
        "Elixir" <> _ ->
          tokens = String.split(mod, ".")
          if length(tokens) == 2 do
            [%{kind: :module, name: List.last(tokens), type: :elixir}|acc]
          else
            acc
          end
        _ ->
          [%{kind: :module, name: mod, type: :erlang}|acc]
      end
    end
  end

  ## Expand calls

  # :atom.fun
  defp expand_call(mod, hint) when is_atom(mod) do
    expand_require mod, hint
  end

  # Elixir.fun
  defp expand_call({:__aliases__, _, list}, hint) do
    expand_require Module.concat(list), hint
  end

  defp expand_call(_, _) do
    no()
  end

  defp expand_require(mod, hint) do
    format_expansion module_funs(mod, hint), hint
  end

  defp expand_import(hint) do
    funs = module_funs(IEx.Helpers, hint) ++
           module_funs(Kernel, hint) ++
           module_funs(Kernel.SpecialForms, hint)
    format_expansion funs, hint
  end

  ## Erlang modules

  defp expand_erlang_modules(hint \\ "") do
    format_expansion match_erlang_modules(hint), hint
  end

  defp match_erlang_modules("") do
    Enum.filter root_modules, fn m -> m.type === :erlang end
  end

  defp match_erlang_modules(hint) do
    Enum.filter root_modules, fn m -> String.starts_with?(m.name, hint) end
  end

  ## Elixir modules

  defp expand_elixir_modules(list, hint) do
    mod = Module.concat(list)
    format_expansion elixir_submodules(mod, hint, list == []) ++ module_funs(mod, hint), hint
  end

  defp elixir_submodules(mod, hint, root) do
    modname = Atom.to_string(mod)
    depth   = length(String.split(modname, ".")) + 1
    base    = modname <> "." <> hint

    Enum.reduce modules_as_lists(root), [], fn(m, acc) ->
      if String.starts_with?(m, base) do
        tokens = String.split(m, ".")
        if length(tokens) == depth do
          name = List.last(tokens)
          [%{kind: :module, type: :elixir, name: name}|acc]
        else
          acc
        end
      else
        acc
      end
    end
  end

  defp modules_as_lists(true) do
    ["Elixir.Elixir"] ++ modules_as_lists(false)
  end

  defp modules_as_lists(false) do
    Enum.map(:code.all_loaded, fn({m, _}) -> Atom.to_string(m) end)
  end

  ## Helpers

  defp module_funs(mod, hint) do
    case ensure_loaded(mod) do
      {:module, _} ->
        falist = get_funs(mod)
                 |> Enum.map(fn {f,a} -> {Atom.to_string(f), a} end)
                 |> Enum.filter(&match_hint(&1, hint))

        list = Enum.reduce falist, [], fn {f, a}, acc ->
          case :lists.keyfind(f, 1, acc) do
            {f, aa} -> :lists.keyreplace(f, 1, acc, {f, [a|aa]})
            false -> [{f, [a]}|acc]
          end
        end

        expand_function_list(mod, hint, list)
      _ ->
        []
    end
  end

  defp match_hint({_fun,_}, ""),  do: true
  defp match_hint({fun,_}, hint), do: String.starts_with?(fun, hint)

  defp expand_function_list(mod, _hint, list) do
    for {fun, arities} <- list do
      %{kind: :function, mod: mod, name: fun, arities: arities}
    end
  end
                       
  defp get_funs(mod) do
    if function_exported?(mod, :__info__, 1) do
      if docs = Code.get_docs(mod, :docs) do
        for {tuple, _line, _kind, _sign, doc} <- docs, doc != false, do: tuple
      else
        (mod.__info__(:functions) -- [__info__: 1]) ++ mod.__info__(:macros)
      end
    else
      mod.module_info(:exports)
    end
  end

  defp ensure_loaded(Elixir), do: {:error, :nofile}
  defp ensure_loaded(mod),    do: Code.ensure_compiled(mod)

  ## Ad-hoc conversions

  defp to_uniq_entries(%{kind: :module}) do
    []
  end

  defp to_uniq_entries(%{kind: :function, mod: mod, name: name}) do
    { :send_doc, mod, name }
  end


  defp to_hint(%{kind: :module, name: name}, hint) do
    :binary.part(name, byte_size(hint), byte_size(name) - byte_size(hint)) <> "."
  end

  defp to_hint(%{kind: :function, name: name}, hint) do
    :binary.part(name, byte_size(hint), byte_size(name) - byte_size(hint))
  end

end
