{CompositeDisposable, Emitter} = require 'atom'
net = require 'net'
path = require 'path'
fs = require 'fs'
NameDialog = require './name-dialog'
markerManager = require './marker-manager'
tooltipManager = require './tooltip-manager'
MySelectListView = require './list'
OuterList = require './outer-list'
UsagesView = require './usage-list'
logger = require './logger'
os = require 'os'
statusBar = require './status-bar'
{$} = require('atom-space-pen-views')

# The component that is responsible for maintaining the connection with
# the server.
module.exports = ClientManager =
  subscriptions: new CompositeDisposable
  emitter: new Emitter # generates connect and disconnect events
  client: null # the client socket
  ready: false # true, if the client can send messages to the server
  stopped: true # true, if disconnected from the server by the user
  jobs: [] # tasks to do after the connection has been established
  incomingMsg: '' # the part of the incoming message already received
  queryNumber: 0
  prevInfL:0
  prevDefL:0
  prevUL:0

  disposeCommands:[]
  dispDefs:null
  definitions:[]
  foundedUsages:[]
  definedinModule:[]
  dispModInfo:null
  currentFileName:null
  panel:null
  selectedText:null
  currentUsage: -1
  serverVersionLowerBound: [1,0,0,0] # inclusive minimum of server version
  serverVersionUpperBound: [1,1,0,0] # exclusive upper limit of server version

  activate: () ->
    statusBar.activate()

    # Register refactoring commands

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:check-server': => @checkServer()

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

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:project-organize-imports', () => @refactor 'ProjectOrganizeImports'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:organize-extensions', () => @refactor 'OrganizeExtensions'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:refactor:project-organize-extensions', () => @refactor 'ProjectOrganizeExtensions'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:jump-to-definition',() => @query 'JumpToDefinition'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:find-usages',() => @query 'GetUsages'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:get-info',() => @query 'GetType'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:get-definitions',() => @query 'DefinedHere'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:module-infos',() => @query 'DefinedInfo'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:get-scope',() => @query 'GetScope'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:next-usage',() => @nextUsage()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:prev-usage',() => @prevUsage()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:disp-us': => @dispUsage()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:undo-refactoring': => @undoRefactoring()

    autoStart = atom.config.get("haskell-tools.start-automatically")

    @emitter.on 'connect', () => @shakeHands()
    @emitter.on 'connect', () => @executeJobs()
    @emitter.on 'connect', () => statusBar.connected()
    @emitter.on 'disconnect', () => statusBar.disconnected()
    @emitter.on 'disconnect', () => markerManager.removeAllMarkers()

    if autoStart
      @connect()

  # Connect to the server. Should not be colled while the connection is alive.
  connect: () ->
    if @ready
      return # already connected

    @client = @createConnection()
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

  createConnection: () ->
    new net.Socket

  # Process an incoming message
  handleMsg: (str) ->
    try
      data = JSON.parse(str)
      if atom.config.get("haskell-tools.debug-mode")
        logger.log('ClientManager: Received: ' + str)
      @incomingMsg = ''
      switch data.tag
        when "KeepAliveResponse" then atom.notifications.addInfo 'Server is up and running'
        when "ErrorMessage"
          atom.notifications.addError data.errorMsg, {dismissable : true}
          statusBar.errorHappened()
        when "LoadedModule"
          markerManager.removeAllMarkersFromFiles [data.loadedModulePath]
          tooltipManager.refresh()
          statusBar.loadedData data.loadedModuleName
        when "LoadingModules" then statusBar.willLoadData data.modulesToLoad
        when "CompilationProblem"
          markerManager.setErrorMarkers(data.markers)
          tooltipManager.refresh()
          isError = data.markers.some (e) -> e.severity == "Error"
          if isError
            statusBar.compilationProblem()
        when "Disconnected" then # will reconnect if needed
        when "UnusedFlags" then atom.notifications.addWarning "Error: The following ghc-flags are not recognized: " + data.unusedFlags, {dismissable: true}
        when "HandshakeResponse"
          wrong = false
          arrayLTE = (arr1, arr2) ->
            for i in [0..Math.min(arr1.length,arr2.length)]
              if arr1[i] < arr2[i] then return true
              if arr1[i] > arr2[i] then return false
            return true
          if !arrayLTE(@serverVersionLowerBound, data.serverVersion) && !arrayLTE(data.serverVersion, @serverVersionUpperBound)
            errorMsg = "The server version is not compatible with the client version. For this client the server version must be at >= #{@serverVersionLowerBound} and < #{@serverVersionUpperBound}. You should probably update both the client and the server to the latest versions."
            atom.notifications.addError errorMsg, {dismissable : true}
            logger.error errorMsg
        when "QueryResult"
          if @queryNumber == 1
            fileName = (data.queryResult)[0]
            row = (data.queryResult)[1]
            atom.workspace.open(fileName).then (editor) ->
              editor.setCursorScreenPosition([row - 1,0])
          else if @queryNumber == 2
            @currentUsage = -1
            @foundedUsages = (data.queryResult).slice 0
            result = []
            l = 0
            while l < @foundedUsages.length
               filename=((data.queryResult)[l])[0]
               str = (@fileNameWithoutPath filename).concat " in line ".concat "#{((data.queryResult)[l])[1]}"
               result.push {show:str,index:l}
               ++l
            editor = atom.workspace.getActiveTextEditor()
            list = new UsagesView result, editor, this, true
           else if @queryNumber == 3
              atom.notifications.addInfo data.queryResult[0],{dismissable : true}
              if data.queryResult[1].length == 0
                  atom.notifications.addInfo "No fixity information",{dismissable : true}
                  atom.notifications.addInfo "No comment for this name",{dismissable : true}
              else
                  if (data.queryResult[1])[0][0] == "" || (data.queryResult[1])[0][0] == undefined
                     atom.notifications.addInfo "No fixity information",{dismissable : true}
                  else
                     atom.notifications.addInfo (data.queryResult[1])[0][0],{dismissable : true}
                  if (data.queryResult[1])[1].length == 0 || (data.queryResult[1])[1] == undefined
                     atom.notifications.addInfo "No comment for this name",{dismissable : true}
                  else
                     result = ""
                     i = 0
                     while i < data.queryResult[1][1].length
                       maybeComment = data.queryResult[1][1][i]
                       if (maybeComment.indexOf "--") > -1 || (maybeComment.indexOf "{-") > -1
                         result += maybeComment
                       ++i
                     result = result.replace /--/g, ""
                     result = result.replace /{-\n/g, ""
                     result = result.replace /-}\n/g, ""
                     result = result.replace /{-/g, ""
                     result = result.replace /-}/g, ""
                     if result == ""
                       atom.notifications.addInfo "No comment for this name",{dismissable : true}
                     else
                       result = "<pre>" + result + "</pre>"
                       atom.notifications.addInfo result,{dismissable : true}

            else if @queryNumber == 4
              i = 0
              console.log data.queryResult.length
              outerArray = []
              while i < data.queryResult.length
                insideArray = []
                j = 0
                filename = data.queryResult[i][0]
                numOfUnqualifs = 0
                while j < (data.queryResult[i][1].length)
                  qualified = data.queryResult[i][1][j][0]
                  unqualified = data.queryResult[i][1][j][1]
                  if unqualified != qualified
                    insideArray.push {show:unqualified,index:data.queryResult[i][1][j][2]}
                    ++numOfUnqualifs
                  ++j
                arr = [data.queryResult[i][0], insideArray]
                str = @fileNameWithoutPath filename
                outerArray.push {show:str,file:filename,inner:insideArray}
                ++i
              editor = atom.workspace.getActiveTextEditor()
              list = @createOuterList outerArray,editor

            else if @queryNumber == 6
              submenuArray = []
              @definedinModule = []
              result = []
              l = 0
              numOfUnqualifs = 0
              while l < data.queryResult.length
                 qualified = data.queryResult[l][0]
                 unqualified = data.queryResult[l][1]
                 if unqualified != qualified
                   @definedinModule.push data.queryResult[l][2]
                   result.push {show:unqualified,index:numOfUnqualifs}
                   ++numOfUnqualifs
                 ++l
              editor = atom.workspace.getActiveTextEditor()
              list = new UsagesView result, editor, this, false


             else if @queryNumber == 7
               result = []
               str = @getModuleNameDot @currentFileName
               i = 0
               while i < data.queryResult.length
                 name = data.queryResult[i]
                 if name.length == 2 && name[0] != name[1]
                   if name[0].startsWith @selectedText# && name[0] != name1
                     result.push name[0]
                   if name[1].startsWith @selectedText# && name1 != name[0]
                     result.push name[1]
                 else
                    if name[2] == "True"
                        name1 = @toQualified name[1], name[3]
                        if name1.startsWith @selectedText
                         result.push name1
                    else
                       if name[1].startsWith @selectedText
                         result.push name[1]
                       name1 = @toQualified name[1], name[3]
                       if name1.startsWith @selectedText
                         result.push name1
                 ++i
                editor = atom.workspace.getActiveTextEditor()
                console.log editor.lineTextForScreenRow 3
                if editor
                  if result.length == 1
                    editor.insertText result[0]
                  else if result.length == 0
                   atom.notifications.addError "No founded name with start #{@selectedText}"
                  else
                   list = new MySelectListView result, editor
                i = 0
                while i < result.length
                  ++i

        else
          atom.notifications.addError 'Internal error: Unrecognized response', {dismissable : true}
          logger.error('Unrecognized response from server: ' + msg)
    catch error
      # probably not the whole message is received
      @incomingMsg = str

  createOuterList:(items, editor)->
    list = new OuterList items, editor, this

  fileNameWithoutPath:(filename) ->
    str = (filename.substr ((filename.lastIndexOf "/") + 1))

  getModuleNameDot:(fileName)->
    str = (fileName.slice (fileName.lastIndexOf "/") + 1,fileName.length-2)

  toUnqualified:(qualifiedName,modName)->
    name1 = qualifiedName.replace modName, ''

  toQualified:(unQualif, qualification)->
    name1 = qualification + "." + unQualif

  nextUsage:->
    if @foundedUsages.length > 0
      ++@currentUsage
      @getUsage @currentUsage %% @foundedUsages.length

  prevUsage:->
    if @foundedUsages.length > 0
      --@currentUsage
      @getUsage @currentUsage %% @foundedUsages.length
      
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
    statusBar.dispose()

  # Disconnect from the server
  disconnect: () ->
    @ready = false
    @stopped = true
    if @client then @client.destroy()

  # Send a command to the server via JSON
  send: (data) ->
    sentData = JSON.stringify(data)
    if atom.config.get("haskell-tools.debug-mode")
      logger.log('ClientManager: Sending: ' + sentData)
    if @ready
      @client.write sentData
      @client.write '\n'
    else atom.notifications.addError("Haskell-tools: Server is not ready. Start the server first.")

  # These functions send commands to the server on user

  checkServer: () ->
    @send {"tag":"KeepAlive","contents":[]}

  refactor: (refactoring) ->
    editor = atom.workspace.getActivePaneItem()
    if not editor
      return
    if editor.isModified()
      if atom.config.get("haskell-tools.save-before-refactor")
        editor.save()
        disp = editor.onDidSave () =>
                 disp.dispose()
                 tryAgain = () =>
                   @refactor(refactoring) # Try again after saving
                 setTimeout tryAgain, 1000 # wait for the file system to inform Haskell-tools
                                           # about the change.
        return
      else
        atom.notifications.addError("Can't refactor unsaved files. Turn-on auto-saving to enable it.")
        return
    file = editor.buffer.file.path
    range = editor.getSelectedBufferRange()

    if refactoring == 'RenameDefinition' || refactoring == 'ExtractBinding'
      dialog = new NameDialog
      dialog.onSuccess ({answer}) =>
        @performRefactor(refactoring, file, range, [ $(answer).find('.line:not(.dummy)').text()])
      dialog.attach()
     else @performRefactor(refactoring, file, range, [])

  getUsage: (i) ->
    fileName = (@foundedUsages[i])[0]
    row = ((@foundedUsages)[i])[1]
    atom.workspace.open(fileName).then (editor) ->
      editor.setCursorScreenPosition([row - 1,0])

  dispUsage:->
    if @foundedUsages != []
      @foundedUsages = []

  queryGetInf:(l) ->
    console.log @definedinModule[l]
    selection = "#{@definedinModule[l][0]}
                 :#{@definedinModule[l][1]}
                 -#{@definedinModule[l][2]}
                 :#{@definedinModule[l][3]}"
    @queryNumber = 3
    @definedinModule = []
    @send {
            'tag':'PerformQuery','query': "GetType"
          , 'modulePath': @currentFileName, 'editorSelection': selection
          , 'details':[], 'shutdownAfter': false
          }


  query: (queryName) ->
     editor = atom.workspace.getActivePaneItem()
     if !editor?
       atom.notifications.addError("The active pane is not .hs file")
     else
       try
         range = editor.getSelectedBufferRange()
         file = editor.buffer.file.path
         selection = "#{range.start.row + 1}:#{range.start.column + 1}-#{range.end.row + 1}:#{range.end.column + 1}"
         switch queryName
           when "JumpToDefinition"
             @queryNumber = 1
           when "GetUsages"
             @queryNumber = 2
           when "GetType"
             @queryNumber = 3
           when 'DefinedHere'
             @queryNumber = 4
           when "DefinedInfo"
            @queryNumber = 6
            @currentFileName = file
           when "GetScope"
              @queryNumber = 7
              @currentFileName = file
              @selectedText = editor.getSelectedText()
         @send {
                 'tag':'PerformQuery','query': queryName
               , 'modulePath': file, 'editorSelection': selection
               , 'details':[], 'shutdownAfter': false
               }
        catch e
           atom.notifications.addError("The active pane is not .hs file")


  performRefactor: (refactoring, file, range, params) ->
    selection = "#{range.start.row + 1}:#{range.start.column + 1}-#{range.end.row + 1}:#{range.end.column + 1}"
    @send { 'tag': 'PerformRefactoring', 'refactoring': refactoring, 'modulePath': file
          , 'editorSelection': selection, 'details': params, 'shutdownAfter': false
          , 'diffMode': false
          }
    statusBar.performRefactoring()


  addPackages: (packages) ->
    if packages.length > 0
      @send { 'tag': 'AddPackages', 'addedPathes': packages }
      statusBar.addPackages()

  removePackages: (packages) ->
    if packages.length > 0
      @send { 'tag': 'RemovePackages', 'removedPathes': packages }
      for pkg in packages
        markerManager.removeAllMarkersFromPackage(pkg)

  reload: (added, changed, removed) ->
    if added.length + changed.length + removed.length > 0
      @send { 'tag': 'ReLoad', 'addedModules': added, 'changedModules': changed, 'removedModules': removed }


  shakeHands: () ->
    pluginVersion = atom.packages.getActivePackage('haskell-tools').metadata.version.split '.'
    @send { 'tag': 'Handshake', 'clientVersion': pluginVersion.map (n) -> parseInt(n,10) }

  undoRefactoring: () ->
    editors = atom.workspace.getTextEditors()
    allSaved = editors.every (e) -> !e.isModified()
    if allSaved then @send { 'tag': 'UndoLast', 'contents': [] }
    else atom.notifications.addError("Can't undo refactoring while there are unsaved files. Save or reload them from the disk.")
