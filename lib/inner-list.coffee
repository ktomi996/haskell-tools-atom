{SelectListView} = require 'atom-space-pen-views'
#List which shows the defined names in module.
#After confirm jumps to the definition.
#If cancelled the cursor remains in the position as before.
module.exports = class InnerListView extends SelectListView
 edit:null
 client:null
 fileName:null
 outerItems:null
 confirm
 initialize:(items,editor,fileName,outerItems,client) ->
   @edit = editor
   @fileName = fileName
   @outerItems = outerItems
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
   try
     row = item.index
     @client.confirmed = true
     atom.workspace.open(@fileName).then (editor) ->
        editor.setCursorScreenPosition([row - 1,0])
     @panel.destroy()
   catch e
     console.log e

 cancelled: ->
   @panel.destroy()
   @client.createOuterList @outerItems, @edit

 getFilterKey:->
   str = 'show'
