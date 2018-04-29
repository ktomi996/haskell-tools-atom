{SelectListView} = require 'atom-space-pen-views'

module.exports = class MySelectListView extends SelectListView
 edit:null
 initialize:(items,editor) ->
   @edit = editor
   super
   @addClass('overlay from-top')
   @setItems(items)

   @panel ?= atom.workspace.addModalPanel(item: this)
   @panel.show()
   @focusFilterEditor()

 viewForItem: (item) ->
    "<li>#{item}</li>"


 confirmed: (item) ->
   console.log("#{item} was selected")
   @edit.insertText item
   @panel.destroy()

 cancelled: ->
   console.log("This view was cancelled")
   @panel.destroy()
