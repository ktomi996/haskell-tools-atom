{SelectListView} = require 'atom-space-pen-views'
InnerList = require './inner-list'
#List which shows the moduls in source code.
#After confirm create an inner list.
#If cancelled the cursor remains in the position as before.
module.exports = class OuterListView extends SelectListView
 edit:null
 client:null
 innerItems:null
 confirm:null
 initialize:(items,editor,client) ->
   @edit = editor
   @innerItems = items
   @confirm = false
   @client = client
   super
   @addClass('overlay from-top')
   @setItems(items)
   @panel ?= atom.workspace.addModalPanel(item: this)
   @panel.show()
   @focusFilterEditor()

 viewForItem: (item) ->
    "<li>#{item.show}</li>"

 confirmed: (item) ->
   @confirm = true
   inner = new InnerList item.inner, @edit, item.file, @innerItems, @client
 cancelled: ->
    @panel.destroy()
    if @confirm == false
      position = @edit.getCursorScreenPosition()
      @client.jumpTo position


 getFilterKey:->
   str = 'show'
