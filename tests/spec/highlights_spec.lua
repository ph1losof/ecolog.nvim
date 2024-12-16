describe("highlights", function()
  local highlights
  local api = vim.api
  
  before_each(function()
    package.loaded["ecolog.highlights"] = nil
    highlights = require("ecolog.highlights")
  end)

  it("should create all required highlight groups", function()
    highlights.setup()
    
    local groups = {
      "EcologNormal",
      "EcologBorder",
      "EcologType",
      "EcologSource",
      "EcologValue",
      "EcologVariable"
    }
    
    for _, group in ipairs(groups) do
      local ok = pcall(api.nvim_get_hl, 0, { name = group })
      assert.is_true(ok, "Highlight group " .. group .. " should exist")
    end
  end)

  it("should link completion highlights correctly", function()
    highlights.setup()
    
    local links = {
      CmpItemKindEcolog = "EcologVariable",
      CmpItemAbbrMatchEcolog = "EcologVariable",
      CmpItemMenuEcolog = "EcologSource"
    }
    
    for group, link in pairs(links) do
      local hl = api.nvim_get_hl(0, { name = group })
      assert.equals(link, hl.link)
    end
  end)
end) 