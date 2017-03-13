{CompositeDisposable, Emitter} = require 'atom'
net = require 'net'
NameDialog = require './name-dialog'
markerManager = require './marker-manager'
logger = require './logger'
history = require './history-manager'
statusBar = require './status-bar'

# The component that is responsible for maintaining the connection with
# the server.
module.exports = ClientManager =
  subscriptions: new CompositeDisposable
  emitter: new Emitter
  client: null
  ready: false
  stopped: true
  jobs: []
  incomingMsg: ''

  activate: () ->
    statusBar.activate()
    history.activate()
    history.onUndo ([changed, removed]) => @reload changed, removed

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:check-server': => @checkServer()

    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      @subscriptions.add editor.onDidSave ({path}) =>
        packages = atom.config.get("haskell-tools.refactored-packages")
        for pack in packages
          if path.startsWith pack
            @whenReady () => @reload [path], []
            return

    @subscriptions.add atom.commands.onDidDispatch (event) =>
      if event.type == 'tree-view:remove'
        removed = event.target.getAttribute('data-name')
        packages = atom.config.get("haskell-tools.refactored-packages")
        for pack in packages
          if removed.startsWith pack
            @whenReady () => @reload [], [removed]
            return

    # Register refactoring commands

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:rename-definition', () => @refactor 'RenameDefinition'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:generate-signature', () => @refactor 'GenerateSignature'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:extract-binding', () => @refactor 'ExtractBinding'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:inline-binding', () => @refactor 'InlineBinding'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:float-out', () => @refactor 'FloatOut'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:organize-imports', () => @refactor 'OrganizeImports'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:generate-exports', () => @refactor 'GenerateExports'

    autoStart = atom.config.get("haskell-tools.start-automatically")

    @emitter.on 'connect', () => @executeJobs()
    @emitter.on 'connect', () => statusBar.connected()
    @emitter.on 'disconnect', () => statusBar.disconnected()

    if autoStart
      @connect()

  # Connect to the server. Should not be colled while the connection is alive.
  connect: () ->
    if @ready
      return # already connected

    @client = new net.Socket
    @stopped = false
    connectPort = atom.config.get("haskell-tools.connect-port")

    @client.connect connectPort, '127.0.0.1', () =>
      logger.log('ClientManager: Connected to Haskell Tools')
      @ready = true
      @emitter.emit 'connect'

    @client.on 'data', (msg) =>
      str = @incomingMsg + msg.toString()
      if str.match /^\s*$/
        return
      logger.log('ClientManager: Received: ' + str)
      for msgPart in str.split '\n'
        @handleMsg msgPart

    @client.on 'close', () =>
      @emitter.emit 'disconnect'
      if @stopped
        logger.log('ClientManager: Connection closed intentionally.')
        return
      logger.log('ClientManager: Connection closed. Reconnecting after 1s')
      @ready = false
      callback = () => @connect()
      setTimeout callback, 1000

  # Process an incoming message
  handleMsg: (str) ->
    try
      data = JSON.parse(str)
      @incomingMsg = ''
      switch data.tag
        when "KeepAliveResponse" then atom.notifications.addInfo 'Server is up and running'
        when "ErrorMessage" then atom.notifications.addError data.errorMsg
        when "LoadedModules"
          markerManager.removeAllMarkersFromFiles data.loadedModules
          statusBar.loadedData data.loadedModules
        when "LoadingModules" then statusBar.willLoadData data.modulesToLoad
        when "CompilationProblem"
          markerManager.setErrorMarkers(data.errorMarkers)
          statusBar.compilationProblem()
        when "ModulesChanged" then history.registerUndo(data.undoChanges)
        when "Disconnected" then # will reconnect if needed
        else
          atom.notifications.addError 'Internal error: Unrecognized response'
          logger.error('Unrecognized response from server: ' + msg)
    catch error
      # probably not the whole message is received
      @incomingMsg = str

  # Registers a callback to trigger when the connection is established/restored
  onConnect: (callback) ->
    @emitter.on 'connect', callback

  # Registers a callback to trigger when the connection is lost
  onDisconnect: (callback) ->
    @emitter.on 'disconnect', callback

  # Execute the given job when thes connection is ready
  whenReady: (job) ->
    if @ready
      job()
    else @jobs.push(job)

  # Perform the jobs that are scheduled for execution
  executeJobs: () ->
    jobsToDo = @jobs
    @jobs = []
    for job in jobsToDo
      job()

  dispose: () ->
    @disconnect()
    @subscriptions.dispose()
    history.dispose()
    statusBar.dispose()

  # Disconnect from the server
  disconnect: () ->
    @ready = false
    @stopped = true
    @client.destroy()

  # Send a command to the server via JSON
  send: (data) ->
    if @ready
      @client.write JSON.stringify(data)
      @client.write '\n'
    else atom.notifications.addError("Haskell-tools: Server is not ready")

  # These functions send commands to the server on user

  checkServer: () ->
    @send {"tag":"KeepAlive","contents":[]}

  refactor: (refactoring) ->
    editor = atom.workspace.getActivePaneItem()
    if not editor
      return
    file = editor.buffer.file.path
    range = editor.getSelectedBufferRange()

    if refactoring == 'RenameDefinition' || refactoring == 'ExtractBinding'
      dialog = new NameDialog
      dialog.onSuccess ({answer}) =>
        @performRefactor(refactoring, file, range, [answer.text()])
      dialog.attach()
    else @performRefactor(refactoring, file, range, [])


  performRefactor: (refactoring, file, range, params) ->
    selection = "#{range.start.row + 1}:#{range.start.column + 1}-#{range.end.row + 1}:#{range.end.column + 1}"
    @send { 'tag': 'PerformRefactoring', 'refactoring': refactoring, 'modulePath': file, 'editorSelection': selection, 'details': params }
    statusBar.performRefactoring()

  addPackages: (packages) ->
    @send { 'tag': 'AddPackages', 'addedPathes': packages }
    statusBar.addPackages()

  removePackages: (packages) ->
    @send { 'tag': 'RemovePackages', 'removedPathes': packages }

  reload: (changed, removed) ->
    @send { 'tag': 'ReLoad', 'changedModules': changed, 'removedModules': removed }
