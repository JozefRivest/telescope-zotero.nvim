local zotero = require 'zotero'
return require('telescope').register_extension {
  exports = {
    zotero = zotero.picker,
    notes = zotero.notes_picker,
  },
}
