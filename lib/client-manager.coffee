{CompositeDisposable, Emitter} = require 'atom'
net = require 'net'
path = require 'path'
fs = require 'fs'
NameDialog = require './name-dialog'
markerManager = require './marker-manager'
tooltipManager = require './tooltip-manager'
MySelectListView = require './list'
OuterList = require './outer-list'
XRegExp = require 'xregexp'
punycode = require 'punycode'
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
  confirmed:false
  definitions:[]
  foundedUsages:[]
  definedinModule:[]
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
      'haskell-tools:query:highlight-extensions', () => @query 'HighlightExtensions'

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
      'haskell-tools:queries:jump-to-definition',() => @dataQuery 'JumpToDefinition'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:find-usages',() => @dataQuery 'GetUsages'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:get-info',() => @dataQuery 'GetType'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:get-definitions',() => @dataQuery 'DefinedHere'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:module-infos',() => @dataQuery 'DefinedInfo'

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:queries:get-scope',() => @dataQuery 'GetScope'

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
          if data.queryType == "MarkerQuery"
            markerManager.setErrorMarkers(data.queryResult)
            tooltipManager.refresh()
            statusBar.ready()

          if data.queryName == "JumpToDefinition" #Jump To Definition
            fileName = (data.queryResult)[0]
            row = (data.queryResult)[1]
            atom.workspace.open(fileName).then (editor) ->
              editor.setCursorScreenPosition([row - 1,0])
          else if data.queryName == "GetUsages" #Find Usages
            @currentUsage = -1
            @foundedUsages = (data.queryResult).slice 0
            result = []
            l = 0
            while l < @foundedUsages.length
               filename=((data.queryResult)[l])[0]
               str2 = (@fileNameWithoutPath filename).concat " in line ".concat "#{((data.queryResult)[l])[1]}"
               result.push {show:str2,index:l}
               ++l
            editor = atom.workspace.getActiveTextEditor()
            list = new UsagesView result, editor, this, true
           else if data.queryName == "GetType" #Get Info
              atom.notifications.addInfo data.queryResult[0],{dismissable : true}
              if data.queryResult[1].length != 0
                  if !((data.queryResult[1])[0][0] == "" || (data.queryResult[1])[0][0] == undefined)
                     atom.notifications.addInfo (data.queryResult[1])[0][0],{dismissable : true}
                  if !((data.queryResult[1])[1].length == 0 || (data.queryResult[1])[1] == undefined)
                     result = ""
                     i = 0
                     while i < data.queryResult[1][1].length
                       maybeComment = data.queryResult[1][1][i]
                       if (maybeComment.indexOf "--") > -1 || (maybeComment.indexOf "{-") > -1
                         result += maybeComment
                       ++i
                     expr = '[\\p{N}\\p{Separator}\\p{Letter}(){},\\];_`\'\[]*'
                     result = result.replace /(\n)type $/, ""
                     result = result.replace /(\n)newtype $/, ""
                     reg = new XRegExp ('(?<first>' + expr + ')--(' + '?<second>' + expr + ')')
                     result =  XRegExp.replace result, reg, '${first}${second}', 'all'
                     result = result.replace /({-\n)|(-}\n)|({-)|(-})/g, ""
                     result = result.replace /(\n)+/g, "\n"
                     if result != ""
                       result = "<pre>" + result + "</pre>"
                       atom.notifications.addInfo result,{dismissable : true}

            else if data.queryName == "DefinedHere" #Get definitions
              i = 0
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
                str2 = @fileNameWithoutPath filename
                outerArray.push {show:str2,file:filename,inner:insideArray}
                ++i
              editor = atom.workspace.getActiveTextEditor()
              list = @createOuterList outerArray,editor

            else if data.queryName == "DefinedInfo" #Get Infos in this modul
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


             else if data.queryName == "GetScope" #Extend names
               if @selectedText == null
                 atom.notifications.addError "Name cannot be found with start #{@selectedText.str}"
               else
                   result = []
                   selected = @selectedText.str
                   i = 0
                   while i < data.queryResult.length
                     name = data.queryResult[i]
                     if name.length == 2 && name[0] != name[1]
                       if name[0].startsWith selected# && name[0] != name1
                         result.push name[0]
                       if name[1].startsWith selected# && name1 != name[0]
                         result.push name[1]
                     else if name.length == 4
                        if name[2] == "True"
                            name1 = @toQualified name[1], name[3]
                            if name1.startsWith selected
                             result.push name1
                        else
                           if name[1].startsWith selected
                             result.push name[1]
                           name1 = @toQualified name[1], name[3]
                           if name1.startsWith selected
                             result.push name1
                     ++i
                    editor = atom.workspace.getActiveTextEditor()
                    if editor
                      if result.length == 1
                        if @selectedText.selected == false
                          editor.insertText result[0]
                        else
                          insert = result[0].substr @selectedText.str.length,result[0].length
                          editor.insertText insert
                      else if result.length == 0
                       atom.notifications.addError "Name cannot be found with start #{@selectedText.str}"
                      else
                       list = new MySelectListView result, editor, @selectedText, this

        else
          atom.notifications.addError 'Internal error: Unrecognized response', {dismissable : true}
          logger.error('Unrecognized response from server: ' + msg)
    catch error
      # probably not the whole message is received
      @incomingMsg = str

  #Returns new OuterList object
  createOuterList:(items, editor)->
    list = new OuterList items, editor, this

  #Returns the filename without the involver folders
  fileNameWithoutPath:(filename) ->
    str = (filename.substr ((filename.lastIndexOf "/") + 1))

  #Returns qualifiedName for short name
  #Parameters: unQualif: the short name
  #qualification: The prefix which extends the short name to qualified with dot
  toQualified:(unQualif, qualification)->
    name1 = qualification + "." + unQualif

  #Get the next usage in foundedUsages array
  nextUsage:->
    if @foundedUsages.length > 0
      ++@currentUsage
      @getUsage @currentUsage %% @foundedUsages.length

  #Get the previous usage in foundedUsages array
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

  #Opens the filename which is the 0th element of
  #ith elemnt of foundedUsages
  #And jumps to the line which is the 1st element of
  #ith elemnt of foundedUsages
  getUsage: (i) ->
    fileName = (@foundedUsages[i])[0]
    row = ((@foundedUsages)[i])[1]
    atom.workspace.open(fileName).then (editor) ->
      editor.setCursorScreenPosition([row - 1,0])

  #Jumps to the given position in the current file
  jumpTo:(position)->
    if @confirmed == false
       atom.workspace.open(@currentFileName).then (editor) ->
         editor.setCursorScreenPosition(position)
    @confirmed = false

  #Clears the usages array
  dispUsage:->
    if @foundedUsages != []
      @foundedUsages = []

  #Starts GetType query with the information in
  #lth element of definedinModule
  queryGetInf:(l) ->
    selection = "#{@definedinModule[l][0]}
                 :#{@definedinModule[l][1]}
                 -#{@definedinModule[l][2]}
                 :#{@definedinModule[l][3]}"
    @definedinModule = []
    @send {
            'tag':'PerformQuery','query': "GetType"
          , 'modulePath': @currentFileName, 'editorSelection': selection
          , 'details':[], 'shutdownAfter': false
          }

  #Returns the length of string
  #The unicode symbols counted only one length
  #source: https://mathiasbynens.be/notes/javascript-unicode
  countSymbolsPedantically:(string)->
	  normalized = string.normalize 'NFC'
	  ret = punycode.ucs2.decode(normalized).length

  #Returns the start position of the selection
  #During the computing the unicode symbols counted only
  #with one length
  getCount:(row,col)->
     textEditor = atom.workspace.getActiveTextEditor()
     line = textEditor.lineTextForScreenRow row
     str = line.substr 0, col
     colSt = @countSymbolsPedantically str

  #Assigns the selectedText variable to the possible start of the
  #typed name from the cursor position.
  #This is left from the cursor and the longest from those which
  #ends of the position of the cursor and fits to the fiven
  #regular expression
  setSelectedText:->
    try
     editor = atom.workspace.getActivePaneItem()
     range = editor.getSelectedScreenRange()
     line = editor.lineTextForScreenRow range.start.row
     str = line.substr 0, range.end.column
     startSmall = '[\\p{Ll}_][\\p{Letter}_\\p{N}\']*'
     startUpper = '[\\p{Lu}_][\\p{Letter}_\\p{N}\']*'
     operator = '[^\\p{N}\\p{Separator}\\p{Letter}(){},\\];_`\'\[]*'
     unicodeWord = XRegExp '('+startUpper+'\.)*' + '((' + startUpper + ')|(' + startSmall + ')|(' + operator + '))?$'
     match = XRegExp.exec str, unicodeWord
     unicodeWord = XRegExp startSmall + '((' + startUpper + ')|(' + startSmall + ')|(' + operator + '))?$'
     match2 = XRegExp.exec str, unicodeWord
     if match2 != null && match[0] != null && match2.length > 0 && (match2[0].endsWith match[0]) && match[0].startsWith '.'
       match[0] = match[0].substr 1,(match.length)
     @selectedText = {selected:true,str:match[0]}
    catch e
      console.log e

  #Starts query to server. The query type is the queryName parameter.
  #Sets the necessary datas.
  dataQuery: (queryName) ->
    try
     editor = atom.workspace.getActivePaneItem()
     if !editor?
       atom.notifications.addError("The active pane is not .hs file")
     else
       try
         range = editor.getSelectedScreenRange()
         file = editor.buffer.file.path
         colSt = @getCount range.start.row, range.start.column
         colEnd = @getCount range.end.row, range.end.column
         selection = "#{range.start.row + 1}:#{colSt + 1}-#{range.end.row + 1}:#{colEnd + 1}"
         if queryName == "DefinedInfo" || queryName == "DefinedHere" || queryName == "GetUsages" || queryName == "GetScope"
            @currentFileName = file
         if queryName == "GetScope"
              if (range.start.row != range.end.row || colSt != colEnd)
               @selectedText = {selected:false,str:editor.getSelectedText()}
              else
                @setSelectedText()
          @send {
                 'tag':'PerformQuery','query': queryName
               , 'modulePath': file, 'editorSelection': selection
               , 'details':[], 'shutdownAfter': false
               }
       catch e
           console.log e
           atom.notifications.addError("The active pane is not .hs file")
    catch m
        console.log m

  performRefactor: (refactoring, file, range, params) ->
    selection = "#{range.start.row + 1}:#{range.start.column + 1}-#{range.end.row + 1}:#{range.end.column + 1}"
    @send { 'tag': 'PerformRefactoring', 'refactoring': refactoring, 'modulePath': file
          , 'editorSelection': selection, 'details': params, 'shutdownAfter': false
          , 'diffMode': false
          }
    statusBar.performRefactoring()

  query: (queryName) ->
    editor = atom.workspace.getActivePaneItem()
    if not editor
      return
    if editor.isModified()
      if atom.config.get("haskell-tools.save-before-refactor")
        editor.save()
        disp = editor.onDidSave () =>
                 disp.dispose()
                 tryAgain = () =>
                   @query(queryName) # Try again after saving
                 setTimeout tryAgain, 1000 # wait for the file system to inform Haskell-tools
                                           # about the change.
        return
      else
        atom.notifications.addError("Can't query unsaved files. Turn-on auto-saving to enable it.")
        return
    file = editor.buffer.file.path
    range = editor.getSelectedBufferRange()

    @performQuery(queryName, file, range, [])

  performQuery: (query, file, range, params) ->
    selection = "#{range.start.row + 1}:#{range.start.column + 1}-#{range.end.row + 1}:#{range.end.column + 1}"
    @send { 'tag': 'PerformQuery'
          , 'query': query
          , 'modulePath': file
          , 'editorSelection': selection
          , 'details': params
          , 'shutdownAfter': false
          }
    statusBar.performQuery()

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
