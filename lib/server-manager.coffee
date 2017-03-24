{CompositeDisposable,Emitter} = require 'atom'
process = require 'child_process'
logger = require './logger'
exeLocator = require './exe-locator'

# Runs the server executable. Starts, stops and restarts it as needed.
# The executable does NOT restart automatically if the executable path changes.
module.exports = ServerManager =
  subproc: null # The subprocess object
  subscriptions: null
  running: false
  emitter: new Emitter # generates started and stopped events

  activate: () ->
    @subscriptions = new CompositeDisposable

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:start-server': => @start()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:stop-server': => @stop()

    @subscriptions.add atom.commands.add 'atom-workspace',
      'haskell-tools:restart-server': => @restart()

    autoStart = atom.config.get("haskell-tools.start-automatically")
    if autoStart
      @start()

  dispose: () ->
    @stop()
    @subscriptions.dispose()

  restart: () ->
    @stop()
    # setting this will re-start the server when we are notified of the termination
    @running = true

  # Starts the executable.
  start: () ->
    if !exeLocator.exeSet()
      atom.notifications.addError("The ht-daemon executable does not exist.")
      return
    if @running
      atom.notifications.addInfo("Cannot start because Haskell Tools is already running.")
      return
    @running = true

    daemonPath = atom.config.get("haskell-tools.daemon-path")
    connectPort = atom.config.get("haskell-tools.connect-port")

    # set verbose mode and channel log messages to our log here
    @subproc = process.spawn daemonPath, [connectPort, 'False']
    @subproc.stdout.on('data', (data) =>
      logger.log('Haskell Tools: ' + data)
    );
    @subproc.stderr.on('data', (data) =>
      logger.error('Haskell Tools: ' + data)
    );
    @subproc.on('close', (code) =>
      # restart the server if it was not intentionally closed
      if @running
        @running = false
        atom.notifications.addError("Unfortunately the server crashed.")
        @start()
    );
    @emitter.emit 'started'

  # Sends a kill signal to the process
  stop: () ->
    if !@running
      atom.notifications.addInfo("Cannot stop because Haskell Tools is not running.")
      return
    @emitter.emit 'stopped'
    @running = false
    @subproc.kill('SIGINT')

  onStarted: (callback) -> @emitter.on 'started', callback
  onStopped: (callback) -> @emitter.on 'stopped', callback
