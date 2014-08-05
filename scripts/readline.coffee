class @Readline

    constructor: (@ip, @prompt) ->
        @history = []
        @search_offset = 0
        @readline_offset = 0
        @ip.
          bind("keydown", "ctrl+p", @previous_line).
          bind('keydown', 'up',     @previous_line).
          bind('keydown', 'ctrl+n', @next_line).
          bind('keydown', 'down',   @next_line).
          bind('keydown', 'ctrl+r', @search_history).
          bind('keydown', 'ctrl+g', @exit_search_history).
          bind('keydown', 'ctrl+u', @clear_line).
          bind('keydown', 'tab',    @tab_complete)

        @ip.autocomplete
            source:   @autocomplete_history_source
            disabled: true
            close:    =>
                @exit_search_history()
                true



    add_history: (line) ->
        @history.push(line)
        @search_offset = @readline_offset = 0

    previous_line: (_ev) =>
        val = @history[@history.length - 1 - @readline_offset];
        if val
            @readline_offset +=1
        @ip.val(val);
        false

    next_line: (_ev) =>
        val = @history[@history.length + 1 - @readline_offset];
        if (val)
            @readline_offset -=1
        @ip.val(val);
        false

    clear_line: =>
        @ip.val('')
        
    search_history:  =>
        @ip.autocomplete
            disabled: false
            source:   @autocomplete_history_source()
            close:    =>
                @exit_search_history()
                true
        @original_prompt = @prompt.text()
        @prompt.text("search:")

    get_matching_history: (term) =>
        value for value in @history when value.match(term)

    exit_search_history: =>
        @ip.autocomplete('destroy')
        $('ul.ui-autocomplete').hide()
        @prompt.text(@original_prompt);

    tab_complete: =>
        @ip.autocomplete
            disabled: false
            source:   @autocomplete_elixir_source()
            response: @check_for_single_element_response
            close:    =>
                @exit_search_history()
                true
            
        @ip.autocomplete('search')
        false

    # We can autocomplete on history or (for tab completion) on
    # elixir names
    autocomplete_history_source: ->
        (request, response) => response(@get_matching_history(request.term))

    autocomplete_elixir_source: ->
        "/autocomplete"

    check_for_single_element_response: (event, response) =>
        switch response.content.length

            when 0
                Util.beep(40, 220)
                
            when 1
                completion = response.content[0].value
                @ip.val(@ip.val() + completion)
                response.content = []
                @ip.autocomplete('disable')
                
            else
                null
