package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

describe("review config", function()
  local config = require("locoreview.config")

  it("returns a validation error for non-table picker config", function()
    local normalized, err = config.normalize({
      picker = false,
    })

    assert.is_nil(normalized)
    assert.is_truthy(err)
    assert.is_truthy(err:match("picker must be a table"))
  end)
end)
