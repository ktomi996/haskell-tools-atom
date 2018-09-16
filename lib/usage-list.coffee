{SelectListView} = require 'atom-space-pen-views'
#List which shows the usages of names or the names in module.
#After confirm jumps to the usage or show the information about the name.
#If cancelled the cursor remains in the position as before.
module.exports = class UsageListView extends SelectListView
 edit:null
 client:null
 usage:null
 confirm:null
 initialize:(items,editor,client,usage) ->
   @edit = editor
   @confirm = false
   super
   @addClass('overlay from-top')
   @setItems(items)
   @client = client
   @usage = usage
   @panel ?= atom.workspace.addModalPanel(item: this)
   @panel.show()
   @focusFilterEditor()

 viewForItem: (item) ->
    "<li>#{item.show}</li>"

 confirmed: (item) ->
   console.log("#{item} was selected")
   @confirm = true
   if @usage == true
    @client.getUsage item.index
   else
    @client.queryGetInf item.index
   @panel.destroy()

 cancelled: ->
   @panel.destroy()
   if @confirm != true
     position = @edit.getCursorScreenPosition()
     @client.jumpTo position

 getFilterKey:->
   str = 'show'
