{SelectListView} = require 'atom-space-pen-views'
InnerList = require './inner-list'
module.exports = class OuterListView extends SelectListView
 edit:null
 client:null
 innerItems:null
 initialize:(items,editor,client) ->
   @edit = editor
   @innerItems = items
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
   console.log("#{item} was selected")
   inner = new InnerList item.inner, @edit, item.file, @innerItems, @client
 cancelled: ->
    @panel.destroy()
