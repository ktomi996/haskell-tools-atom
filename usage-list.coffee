{SelectListView} = require 'atom-space-pen-views'

module.exports = class UsageListView extends SelectListView
 edit:null
 client:null
 usage:null
 initialize:(items,editor,client,usage) ->
   @edit = editor
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
   if @usage == true
    @client.getUsage item.index
   else
    @client.queryGetInf item.index
   @panel.destroy()

 cancelled: ->
   console.log("This view was cancelled")
   @panel.destroy()
