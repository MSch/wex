class @Editor

    constructor: (@file_loader, rest, @ws) ->
        @editor = ace.edit("ace")
        @editor.setTheme("ace/theme/monokai")
        session = @editor.getSession()
        session.setMode("ace/mode/elixir")
        @current_file = null
        @compiler = new Compiler(@ws, rest, @, @editor)
        WexEvent.handle(WexEvent.load_file,           "Editor", @load_file)
        WexEvent.handle(WexEvent.open_file_in_editor, "Editor", @open_file)
        @create_sandbox()

    load_file: (event, file_node) =>
        if EditorFileList.is_file_in_list(file_node.id)
            EditorFileList.make_active(file_node)
        else
            @file_loader.load(file_node.id,
                ((file_from_server) => @load_ok(file_from_server, file_node)),
                @load_failed)

    load_ok: (file_from_server, file_node) =>
        console.dir file
        if file_from_server.status == "ok"
            @edit(file_node, file_from_server.content)
        else
            alert "Couldn't load #{file_from_server.path}: #{file_from_server.message}"
            
    load_failed: (event) =>
        console.log "failed"
        console.dir event

    edit: (file_node, content) ->
        file_node.content  = content
        file_node.document = ace.createEditSession(content, "ace/mode/elixir")
        EditorFileList.make_active(file_node)
        
    open_file: (_event, file) =>
        @editor.setSession file.document
        @current_file = file
        @add_errors(file)
        @compile_on_changes()

    record_error: (error) ->
        if file = EditorFileList.find_file_node_in_list(error.file)
            file.record_error(error)
            if file == @current_file
                @add_errors(file)
        else
            alert "Cannot record error for #{error.file}"
        
    clear_all_errors: =>
        EditorFileList.clear_all_errors()
        @editor
        .getSession()
        .clearAnnotations()

    add_errors: (file) ->
        annotations = (@annotation_for(error) for error in file.errors)
        @editor
        .getSession()
        .setAnnotations(annotations)

    annotation_for: (error) ->
        if error.line == 0
            error.line = @editor
                        .getSession()
                        .getDocument()
                        .getLength()
                        
        { row: error.line - 1, type: error.type || "error", text: error.error }
        
    create_sandbox: ->
        sandbox = new Files.File("wex sandbox", "wex sandbox")
        @edit(sandbox, "# This is the sandbox. Have fun!")

    compile_on_changes: ->
        @editor.session.on "change", @reset_timer
        @trigger_compilation()

    set_timer: =>
        @timer = setTimeout @trigger_compilation, 600

    reset_timer: =>
        clearTimeout @timer
        @set_timer()

    trigger_compilation: =>
        @compiler.compile_file()
        
        
