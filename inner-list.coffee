{SelectListView} = require 'atom-space-pen-views'
module.exports = class InnerListView extends SelectListView
 edit:null
 client:null
 fileName:null
 outerItems:null
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
   row = item.index
   atom.workspace.open(@fileName).then (editor) ->
      editor.setCursorScreenPosition([row - 1,0])
   @panel.destroy()

 cancelled: ->
   @client.createOuterList @outerItems, @edit
    #list = new Helper @outerItems, @edit
