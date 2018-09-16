{SelectListView} = require 'atom-space-pen-views'
#List which shows the possibilities to extend name.
#After confirm extends the name.
#If cancelled the cursor remains in the position as before.
module.exports = class MySelectListView extends SelectListView
 edit:null
 selectedText:null
 position:null
 client:null
 initialize:(items,editor,selectedText,client) ->
   @edit = editor
   @client = client
   @selectedText = selectedText
   super
   @addClass('overlay from-top')
   @setItems(items)
   @panel ?= atom.workspace.addModalPanel(item: this)
   @panel.show()
   @focusFilterEditor()
   @filterEditorView.setText selectedText.str

 viewForItem: (item) ->
    "<li>#{item}</li>"

 confirmed: (item) ->
   @panel.destroy()
   try
     if @selectedText.selected == false
       @edit.insertText item
     else
       insert = item.substr @selectedText.str.length,item.length
       @edit.insertText insert
     @getCursorTo()
   catch e
     console.log e

 getCursorTo:->
    position = @edit.getCursorScreenPosition()
    @client.jumpTo position

 cancelled: ->
   @panel.destroy()
   @getCursorTo()
