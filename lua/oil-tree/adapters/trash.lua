local fs = require("oil-tree.fs")

if fs.is_mac then
  return require("oil-tree.adapters.trash.mac")
elseif fs.is_windows then
  return require("oil-tree.adapters.trash.windows")
else
  return require("oil-tree.adapters.trash.freedesktop")
end
